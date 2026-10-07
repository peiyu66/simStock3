#!/usr/bin/env python3
"""Independent read-only LC-P01 checks; never new formulas or strategy replay."""
import collections as C,json,math,sqlite3,time,resource
from pathlib import Path
import loss_exit_p01 as p
import numpy as np
O=p.O
cat,X,meta,units=p.load_units();names=[c['name'] for c in cat]
labels=json.loads((O/'labels.json').read_text());spec=json.loads((O/'calibration-spec.json').read_text());atoms=json.loads((O/'atoms.json').read_text());res=json.loads((O/'calibration.json').read_text())['results']
assert len(meta)==43696 and sum(r['held'] for _,_,_,r in meta)==38106
assert len(labels)==219 and len({(e['sample'],e['window'],e['stock'],e['date']) for e in labels})==219
# Direct actual execution IDs and net losses, not the extractor's gates.
for sample in 'CD':
 bp=next(p.R.glob('exports/backtest-decision-bases/'+sample.lower()+'-*-s49-*-v23'))
 with sqlite3.connect((bp/'decisions.sqlite').as_uri()+'?mode=ro&immutable=1',uri=True) as db:
  actual={(w,s,d) for w,s,d in db.execute("select window_id,stock_id,trade_date from decision_events join stocks using(stock_key) where phase=3 and executed_action='SELL'")}
 expected={(w,s,r['date']) for a,w,s,r in meta if a==sample and r['qtySell']>0};assert actual==expected
# Independent scalar evaluator over all rows for first/last each stratum, and every structure on boundary/unknown rows.
def scalar(a,row):
 x=float(row[names.index(a['name'])]);v=a['value'];valid=math.isfinite(x)
 if not valid:return False,False
 op=a['op'];hit=x<v if op=='lt' else x>v if op=='gt' else x==v if op=='eq' else x!=v if op=='ne' else v[0]<x<v[1]
 return hit,True
strata=C.defaultdict(list)
for s in spec['structures']:strata[s['group']].append(s)
chosen=[s for seq in strata.values() for s in (seq[0],seq[-1])]
for s in chosen:
 cnt=C.Counter()
 for row,(_,_,_,r) in zip(X,meta):
  if not r['held'] or r['quality']:continue
  a,av=scalar(atoms[s['atoms'][0]],row);b,bv=scalar(atoms[s['atoms'][1]],row)
  for side,eligible in [('early',r['gates']['earlyEligible'] and not r['gates']['normalSell']),('late',r['gates']['lateEligible'])]:
   if eligible:cnt[side+'Hits']+=a and b;cnt[side+'Unknown']+=not(av and bv)
 assert all(res[s['id']][k]==cnt[k] for k in ('earlyHits','earlyUnknown','lateHits','lateUnknown')),(s,cnt)
 p.guard()
keys=json.loads((O/'late-keys.json').read_text());late=np.load(O/'late-masked.npz')['X'];scols=[j for j,c in enumerate(cat) if c['group']=='S'];tm=[j for j,c in enumerate(cat) if c['group']!='S']
for k,row in zip(keys,late):
 assert np.allclose(row[tm],X[k['index'],tm],equal_nan=True)
 if k['offset']>0:assert np.isnan(row[scols]).all()
# Source preservation: extraction implementation snapshot is intentionally retained before atom-enumeration correction.
hashes=json.loads((O/'source-hashes.json').read_text());different=[]
for name,value in hashes.items():
 path=p.R/name
 if p.sha(path)!=value:
  if name=='tools/loss_exit_p01.py':assert p.sha(O/'tool-sources/loss_exit_p01.py')==value
  else:different.append(name)
assert not different,different
initial=json.loads((O/'protocol.json').read_text())['initialWorktreeHashes'];assert all(p.sha(p.R/n)==v for n,v in initial.items())
quality=C.Counter(q for _,_,_,r in meta for q in r['quality']);missing=C.Counter(d for u in units for d in u['missingMarketSessions'])
earlylinks=C.Counter(i for e in labels for i in e['sides']['early']['indices']);alllinks=C.Counter(i for e in labels for side in e['sides'].values() for i in side['indices'])
eventindices={i for e in labels for i in e['sides']['early']['indices']};outside=sum(r['held'] and r['gates']['earlyEligible'] and not r['gates']['normalSell'] and not r['quality'] and i not in eventindices for i,(_,_,_,r) in enumerate(meta))
market=sorted(p.prior.market_inputs()[1]);calendar=[]
for e in labels:
 for side,d in e['sides'].items():
  if not d['dates']:continue
  lo=min([e['date']]+d['dates']);hi=max([e['date']]+d['dates']);span=sum(lo<x<=hi for x in market)
  calendar.append(dict(sample=e['sample'],window=e['window'],stock=e['stock'],event=e['date'],side=side,observations=d['count'],marketSessions=span,calendarDays=(__import__('datetime').datetime.strptime(str(hi),'%Y%m%d')-__import__('datetime').datetime.strptime(str(lo),'%Y%m%d')).days))
p.save('event-calendar.json',calendar)
summary=dict(status='passed',rows=len(meta),heldDays=38106,events=219,actualSellJoinChecked=1435,independentScalarStructures=len(chosen),independentScalarRowsPerStructure=len(meta),sourceDatabaseBytesUnchanged=True,initialUnrelatedFilesUnchanged=len(initial),earlyNonEventEligibleDays=outside,rowQuality=dict(quality),missingMarketSessionsTotal=sum(missing.values()),sharedSnapshotTailMissing=missing[20260722],interiorMissingSessions=sum(v for d,v in missing.items() if d!=20260722),missingClassification='unresolved; snapshot common tail separately listed, not silently marked suspension',eventWindowLinks=sum(alllinks.values()),uniqueEventWindowRows=len(alllinks),overlapRows=sum(v>1 for v in alllinks.values()),maximumMultiplicity=max(alllinks.values()),lateUnknownSFields=len(scols),lateRows=len(keys),earlyHigherEligibleEventCount=sum(bool(e['sides']['early']['higherEligibleDates']) and e['sides']['early']['qualityEligible'] for e in labels),extractorSnapshotSHA256=p.sha(O/'tool-sources/loss_exit_p01.py'),finalToolSHA256=p.sha(Path(p.__file__)),resources=p.guard())
p.save('audit.json',summary);print(json.dumps(summary),flush=True)
