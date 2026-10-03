#!/usr/bin/env python3
"""Independent EA artifact relations, identity and first-action audit."""
import collections as C,hashlib,json,math,resource,time
from pathlib import Path
R=Path(__file__).resolve().parents[1];O=R/'exports/entry-advance-20261003';start=time.monotonic()
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
source=json.loads((O/'source-hashes.json').read_text())
for p,h in source.items():assert sha(R/p)==h,p
units={u:json.loads((O/'units'/f'{u}.json').read_text()) for u in json.loads((O/'extraction-complete.json').read_text())['units']};checks=C.Counter();summ={}
for uid,u in units.items():
 rows={r['date']:r for r in u['rows']};assert len(rows)==len(u['rows'])
 for e in u['events']:
  assert rows[e['date']]['originalBuy']==e['rule'];assert len(e['prior'])<=10;assert all(r['date']<e['date'] for r in e['prior']);checks['entryRelations']+=1
  assert len(set(r['date'] for r in e['prior']))==len(e['prior'])
for cid in ('EA-H01','EA-L01'):
 x=json.loads((O/('card-'+cid+'.json')).read_text());seen=set();first={};dist={};pairs=[]
 for r in x['shadowDays']:
  key=(r['unit'],r['date']);assert key not in seen;seen.add(key);u=units[r['unit']];original=next(a for a in u['rows'] if a['date']==r['date']);assert original['feasible'] and not original['quality'];f=original['features'];assert f==r['features']
  if cid=='EA-H01':assert f['ma20']>0 and f['m20']>0 and f['hMargin']==-1
  else:assert f['ma20']<0 and f['dm20']>0 and f['lMargin']==-1
  first.setdefault(r['unit'],r)
  for e in r['linkedEvents']:
   originalEvent=next(a for a in u['events'] if a['date']==e['date']);assert r['date'] in [a['date'] for a in originalEvent['prior']]
   v=100*(originalEvent['price']-r['price'])/originalEvent['price'];assert math.isclose(v,e['savingPct'],abs_tol=1e-8)
  checks['shadowRows']+=1
 assert list(first.values())==x['firstDivergences']
 for phase in ('discovery','frozenCheck'):
  ev=[e for e in x['eventComparisons'] if e['phase']==phase];ff=[r for r in first.values() if r['phase']==phase];dd=C.Counter()
  for e in ev:
   v=e['savingPct'];dd['lowerOver1' if v>1 else 'lower0to1' if v>0 else 'same' if v==0 else 'higher0to1' if v>=-1 else 'higher1to5' if v>=-5 else 'higherOver5']+=1
  firstLabels=C.Counter()
  for r in ff:
   # Nearest future original entry; other linked future entries remain relations only.
   ee=sorted(r['linkedEvents'],key=lambda e:e['date'])
   firstLabels['outside' if not ee else 'lower' if ee[0]['savingPct']>0 else 'higher' if ee[0]['savingPct']<0 else 'equal']+=1
  stockContribution=C.Counter()
  for e in ev:
   if e['savingPct']>0:stockContribution[e['stock']]+=1
  best=stockContribution.most_common(1)
  dist[phase]={'events':len(ev),'stocks':len({e['stock'] for e in ev}),'priceDifferenceBins':dict(dd),'firstDivergences':len(ff),'firstLabels':dict(firstLabels),'crossSegmentComparisons':sum(not e['sameSegment'] for e in ev),'removeLargestPositiveStock':{'stock':best[0][0] if best else None,'remainingLower':sum(stockContribution.values())-(best[0][1] if best else 0)},'byOriginalRule':{rule:dict(C.Counter('lower' if e['savingPct']>0 else 'higher' if e['savingPct']<0 else 'equal' for e in ev if e['originalRule']==rule)) for rule in 'HL'}}
 summ[cid]=dist
save={'checks':dict(checks),'sourcesUnchanged':len(source),'candidateDetails':summ,'resources':{'wallSeconds':time.monotonic()-start,'peakRSSBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss},'notes':['PriceDifferenceBins are descriptive percent, not efficiency >+1 scores.','No candidate outcome or own S beyond first divergence exists.']}
(O/'audit.json').write_text(json.dumps(save,ensure_ascii=False,indent=2));print(json.dumps(save,ensure_ascii=False,indent=2))
