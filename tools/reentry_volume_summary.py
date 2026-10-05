#!/usr/bin/env python3
"""Complete predeclared VRI comparisons, including un-released opportunities.

Observational accounting only: never estimates candidate trading performance.
"""
import collections as C,json,statistics as S,time,resource
from pathlib import Path
R=Path(__file__).resolve().parents[1]; O=R/'exports/vri-p00-p03-20261005';V=R/'exports/vcx-p01-p04-20261005'
START=time.monotonic();resource.setrlimit(resource.RLIMIT_CPU,(900,900))
def rd(p):return json.loads(p.read_text())
def mean(a):return S.mean(a) if a else None
def desc(a):
 rel=[x for x in a if x['releaseDeltaPct'] is not None]
 return dict(n=len(a),outcomes=dict(C.Counter(x['roundOutcome'] for x in a)),status=dict(C.Counter(x['releaseStatus'] for x in a)),lower=sum(x['releaseDeltaPct']< -1e-8 for x in rel),higher=sum(x['releaseDeltaPct']>1e-8 for x in rel),same=sum(abs(x['releaseDeltaPct'])<=1e-8 for x in rel),meanReleaseDeltaPct=mean([x['releaseDeltaPct'] for x in rel]),bySample=dict(C.Counter(x['sample'] for x in a)),byWindow=dict(C.Counter(x['window'] for x in a)))
def corr(a,b):return S.correlation(a,b) if len(a)>1 else None
def main():
 assert rd(O/'audit.json')['passed'];seg={s['id']:s for s in rd(O/'segments.json')};summary=[]
 for h in rd(O/'hypotheses-frozen.json'):
  x=rd(O/'paths'/f'{h["id"]}-full.json');b={a['id']:a for a in rd(O/'paths'/f'{h["id"]}-background.json')}
  first={};dates=C.defaultdict(list);blocked=[];paired=[]
  for a in sorted(x,key=lambda a:a['entryDate']):
   first.setdefault(a['unit'],a);dates[a['entryDate']].append(a)
   if a['releaseDate'] and b[a['id']]['releaseDate']:paired.append(a['releaseDeltaPct']-b[a['id']]['releaseDeltaPct'])
   if not a['releaseDate']:
    s=seg[a['id']];rows=rd(V/'units'/(a['unit']+'.json'))['rows'];end=s['roundEndIndex'] if s['roundEndIndex'] is not None else len(rows)-1
    blocked.append(dict(id=a['id'],outcome=a['roundOutcome'],status=a['releaseStatus'],endPriceDeltaPct=100*(rows[end]['price']/a['entryPrice']-1)))
  allmarks=[a['releaseDeltaPct'] for a in x if a['releaseDate']]+[a['endPriceDeltaPct'] for a in blocked]
  # Market proxies are deduplicated by decision date. They describe overlap,
  # never provide extra independent market evidence or alternative candidates.
  md={}
  for a in b.values():
   f=a['features'];q=(f['mvz'],f['valuez'],f['transz']);assert a['entryDate'] not in md or md[a['entryDate']]==q;md[a['entryDate']]=q
  z=list(md.values());activity=dict(dates=len(z),volumeValueCorrelation=corr([a[0] for a in z],[a[1] for a in z]),volumeTransactionsCorrelation=corr([a[0] for a in z],[a[2] for a in z]),volumeHotDays=sum(a[0]>1 for a in z),valueHotDays=sum(a[1]>1 for a in z),transactionsHotDays=sum(a[2]>1 for a in z),allThreeHotDays=sum(all(v>1 for v in a) for a in z))
  releasedDates=[mean([a['releaseDeltaPct'] for a in group if a['releaseDate']]) for group in dates.values()];releasedDates=[a for a in releasedDates if a is not None]
  record=dict(hypothesis=h['id'],firstPerStockWindow=desc(list(first.values())),sameEventsBackground=desc([b[a['id']] for a in x]),pairedReleaseCount=len(paired),pairedFullMinusBackgroundPricePct=mean(paired),releasedWhenBackgroundNeverReleases=desc([a for a in x if a['releaseDate'] and not b[a['id']]['releaseDate']]),unreleased=desc([a for a in x if not a['releaseDate']]),unreleasedEndMarks=blocked,allOpportunityEndOrReleaseMarkMeanPct=mean(allmarks),marketDateCount=len(dates),releaseDateGroupMeanPct=mean(releasedDates),marketActivitySensitivity=activity)
  summary.append(record);print(h['id'],record['firstPerStockWindow'],record['allOpportunityEndOrReleaseMarkMeanPct'],flush=True)
  assert time.monotonic()-START<900 and resource.getrusage(resource.RUSAGE_SELF).ru_maxrss<1073741824
 result=dict(comparisons=summary,interpretation='All opportunity mark is descriptive price accounting, not feasible fills, returns, cash, or candidate score. Positive marks include missed rises. No extra hypotheses or masks.',strategyReplay=False,wallSeconds=time.monotonic()-START,cpuSeconds=time.process_time(),peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
 (O/'paired-first-and-censoring.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
if __name__=='__main__':main()
