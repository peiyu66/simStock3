#!/usr/bin/env python3
"""EA case comparisons and a small explicitly frozen hypothesis batch."""
import collections as C,json,statistics as S,hashlib,time,resource
from pathlib import Path
R=Path(__file__).resolve().parents[1];O=R/'exports/entry-advance-20261003'
def save(n,x):(O/n).write_text(json.dumps(x,ensure_ascii=False,allow_nan=False,indent=2)+'\n')
def units():
 for uid in json.loads((O/'extraction-complete.json').read_text())['units']:yield json.loads((O/'units'/f'{uid}.json').read_text())
def discovery(u):return u['sample'] in 'ABCD' and u['window']<3
def links(u):
 rows={r['date']:r for r in u['rows']}
 for e in u['events']:
  for a in e['prior']:
   r=rows.get(a['date'])
   if r and r['feasible'] and not r['quality'] and not r['normal']:
    yield e,r,100*(e['price']-r['price'])/e['price']
def singles():
 counts=C.Counter();samples={};factors=C.defaultdict(list);examples=[]
 for u in units():
  cs=C.Counter();rows={r['date']:r for r in u['rows']}
  for e in u['events']:
   cs['entries']+=1;cs['leftTruncated']+=e['leftTruncated'];cs['gapEvents']+=bool(e['missingMarketSessions']);available=[]
   for a in e['prior']:
    if not a['flat']:cs['heldPriorLinks']+=1;continue
    r=rows[a['date']]
    if not r['feasible']:cs['executionBlockedLinks']+=1;continue
    if r['quality']:cs['qualityBlockedLinks']+=1;continue
    if r['normal']:cs['alreadyNormalLinks']+=1;continue
    available.append((r,100*(e['price']-r['price'])/e['price']))
   cs['eventsWithEligiblePrior']+=bool(available);cs['eventsWithLower']+=any(v>0 for r,v in available);cs['eventsNoLowerComplete']+=bool(available and not e['leftTruncated'] and not e['missingMarketSessions'] and not any(v>0 for r,v in available))
   cs['eligibleLinks']+=len(available);cs['crossSegmentLinks']+=sum(r['segment']!=e['segment'] for r,v in available)
   if discovery(u):
    for label,test in [('lower',lambda v:v>0),('higher',lambda v:v<0),('equal',lambda v:v==0)]:
     rr=[r for r,v in available if test(v)]
     if not rr:continue
     for k in rr[0]['features']:
      vals=[r['features'][k] for r in rr if r['features'][k] is not None]
      if vals:factors[k,label].append(S.mean(vals))
    if available:
     r,v=min(available,key=lambda x:x[0]['date']);examples.append({'unit':f'{u["sample"]}-{u["window"]}-{u["stock"]}','event':e['date'],'rule':e['rule'],'date':r['date'],'savingPct':v,'features':r['features'],'sameSegment':r['segment']==e['segment']})
  counts.update(cs);samples.setdefault(u['sample'],C.Counter()).update(cs)
 summary={k:{l:{'events':len(factors[k,l]),'medianOfEventMeans':S.median(factors[k,l]) if factors[k,l] else None,'positiveEventMeans':sum(v>0 for v in factors[k,l])} for l in ('lower','higher','equal')} for k in sorted({k for k,l in factors})}
 save('case-inventory.json',{'all':dict(counts),'samples':{k:dict(v) for k,v in samples.items()}});save('single-factor.json',summary);save('first-case-examples.json',examples)
 print(json.dumps(dict(counts)))
 for k in ('ma20','ma60','osc','d20','do','dk','m20','dm20','mo','dmo','hMargin','lMargin','grade'):
  print(k,summary[k])

def freeze():
 cards=[{'id':'EA-H01','branch':'H','terms':[['ma20','>',0],['m20','>',0]],'action':'flat-only H +1 before H-T01; preserve H-E01/02 and H-first routing','mechanism':'個股在短均線之上且市場亦在短均線之上，順勢參與，放寬差一票的追高','evidence':'市場MA20在較低價事件的均值中位0.837，高價0.570；個股MA20本身不分勝負，作追高情境而非勝率保證'},
 {'id':'EA-L01','branch':'L','terms':[['ma20','<',0],['dm20','>',0]],'action':'flat-only L +1 before L-T01, only when original H fails; preserve H-first routing','mechanism':'個股仍在短均線下承低，但市場短均線乖離正在改善，補一票以提前低接','evidence':'市場MA20增量較低價事件均值中位+0.0105，高價-0.101；個股MA20<0指定承低情境，仍可能接到持續下跌'}]
 p=O/'frozen-cards.json';assert not p.exists();save(p.name,{'cards':cards,'discovery':'A-D W1/W2 only','thresholdSearch':False,'timestamp':time.time(),'rule':'7ba8447fbf207484ab305cad0c6beca216da8c93','scope':'two hypotheses, no strategy replay; no future input'})

def checkcards():
 import sqlite3,math
 from entry_advance import qty,day,guard
 def db(p):
  wal=Path(str(p)+'-wal');assert not wal.exists() or wal.stat().st_size==0
  c=sqlite3.connect(p.as_uri()+'?mode=ro&immutable=1',uri=True);c.row_factory=sqlite3.Row;return c
 frozen=json.loads((O/'frozen-cards.json').read_text());result={}
 mpath=R/'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af/market-technical.csv'
 import csv
 with mpath.open() as f:market={int(x['date'].replace('-','')):x for x in csv.DictReader(f)}
 def match(card,r):
  f=r['features']
  return all(f[k] is not None and (f[k]>v if op=='>' else f[k]<v) for k,op,v in card['terms'])
 for card in frozen['cards']:
  existing=O/('card-'+card['id']+'.json')
  if existing.exists():
   cache=json.loads((O/('cache-'+card['id']+'.json')).read_text())
   for path,digest in cache.items():assert hashlib.sha256((R/path).read_bytes()).hexdigest()==digest,('cache identity changed',path)
   result[card['id']]=json.loads(existing.read_text());continue
  first=[];eventrows=[];shadow=[];counts=C.Counter();by=C.defaultdict(C.Counter)
  for u in units():
   save('analysis-progress.json',{'candidate':card['id'],'unit':[u['sample'],u['window'],u['stock']],'resources':guard()});print(card['id'],u['sample'],u['window'],u['stock'],flush=True)
   phase='discovery' if discovery(u) else 'frozenCheck';uid=f'{u["sample"]}-{u["window"]}-{u["stock"]}';rows={r['date']:r for r in u['rows']};eventmap=C.defaultdict(list)
   for e,r,v in links(u):eventmap[r['date']].append((e,v))
   rp=next(R.glob('exports/backtest-reports/baseline-'+u['sample'].lower()+'-v37-*-fixed3y-*'));fn=('browse.store','period-20200722.store','period-20230722.store')[u['window']-1]
   with db(rp/fn) as c:
    raw={day(x['ZDATETIME']):dict(x) for x in c.execute('select t.* from ZTRADE t join ZSTOCK s on t.ZSTOCK=s.Z_PK where s.ZSID=?',(u['stock'],))}
   hits=[]
   for r in u['rows']:
    if not r['feasible'] or r['quality'] or not match(card,r):continue
    f=r['features'];d=r['date'];rr=raw[d];m=market[d]
    if card['branch']=='H':
     if f['hMargin']!=-1:continue
     # H delays need re-evaluation after candidate crosses the score threshold.
     deferred=(f['mphase']==7 and f['mjz']>-.88 and (f['grade']>=1 or f['ma60']>-3.6)) or (f['dz']<-.85 and -10<float(m['market_high_diff_250'])<-1.7 and (rr['ZTHIGHDIFF']>2.2 or rr['ZTLOWDIFFZ250']<-.92))
     if deferred:counts[phase+'Deferred']+=1;continue
    else:
     if f['lMargin']!=-1:continue
    if r['normal']:
     counts[phase+'ExistingLReclassifiedH']+=1
     # H replacing a normal L is also an actual first decision divergence.
     hits.append((r,'labelChange'));continue
    hits.append((r,'newEntry'))
   seen=set()
   for r,kind in hits:
    linked=eventmap[r['date']];record={'unit':uid,'sample':u['sample'],'window':u['window'],'stock':u['stock'],'name':u['name'],'date':r['date'],'segment':r['segment'],'kind':kind,'features':r['features'],'price':r['price'],'qty':r['qty'],'phase':phase,'linkedEvents':[{'date':e['date'],'rule':e['rule'],'savingPct':v,'sameSegment':e['segment']==r['segment'],'gap':bool(e['missingMarketSessions']),'truncated':e['leftTruncated']} for e,v in linked]}
    shadow.append(record);counts[phase+'HitDays']+=1
    if r['segment'] not in seen:
     counts[phase+'UniqueSegments']+=1;seen.add(r['segment'])
    if not linked:counts[phase+'OutsideEventWindowDays']+=1
   if hits:
    record=next(x for x in shadow if x['unit']==uid);first.append(record)
   for e in u['events']:
    eligible=[r for r,k in hits if k=='newEntry' and r['date'] in {a['date'] for a in e['prior']}]
    if not eligible:continue
    r=eligible[0];v=100*(e['price']-r['price'])/e['price'];label='lower' if v>0 else 'higher' if v<0 else 'equal'
    record={'unit':uid,'stock':u['stock'],'name':u['name'],'window':u['window'],'phase':phase,'event':e['date'],'originalRule':e['rule'],'date':r['date'],'savingPct':v,'sameSegment':e['segment']==r['segment'],'gap':bool(e['missingMarketSessions']),'truncated':e['leftTruncated']}
    eventrows.append(record);by[phase][label]+=1;by[phase][u['sample']+str(u['window'])]+=1
  result[card['id']]={'counts':dict(counts),'events':{k:dict(v) for k,v in by.items()},'firstDivergences':first,'eventComparisons':eventrows,'shadowDays':shadow,'limitations':'only first stock/window divergence is causally valid; later baseline path is shadow exposure, not simulated candidate outcomes'}
  save('card-'+card['id']+'.json',result[card['id']])
  save('cache-'+card['id']+'.json',{str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (Path(__file__),O/'frozen-cards.json',O/'extraction-complete.json',O/('card-'+card['id']+'.json'))});print(card['id'],dict(counts),{k:dict(v) for k,v in by.items()})
 save('analysis-resources.json',guard())
 save('candidate-summary.json',{k:{x:v[x] for x in ('counts','events')} for k,v in result.items()})

if __name__=='__main__':
 import argparse
 p=argparse.ArgumentParser();p.add_argument('stage',choices=['singles','freeze','cards']);args=p.parse_args()
 {'singles':singles,'freeze':freeze,'cards':checkcards}[args.stage]()
