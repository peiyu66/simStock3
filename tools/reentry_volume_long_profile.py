#!/usr/bin/env python3
"""Describe predeclared LT states and raw-mean contrasts; no new hypotheses."""
import bisect,collections as C,json,math,statistics as S
from pathlib import Path
R=Path(__file__).resolve().parents[1];O=R/'exports/vri-long-20261006'
def rd(n):return json.loads((O/n).read_text())
def out(xs):return dict(n=len(xs),outcomes=dict(C.Counter(x['outcome'] for x in xs)),stocks=len(set(x['stock'] for x in xs)),dates=len(set(x['date'] for x in xs)),byWindow=dict(C.Counter(x['window'] for x in xs)))
def comparison(child,parent):
 p={x['id']:x for x in parent};ids={x['id'] for x in child};paired=[x['delta']-p[x['id']]['delta'] for x in child if x['status']=='released' and p[x['id']]['status']=='released'];closed=[x for x in parent if x['roundOutcome']!='censored'];cuts={}
 for k in ('flatTradingDays','entryRelativeSellPct','z125'):
  a=sorted(x['features']['z125'] if k=='z125' else x[k] for x in closed);cuts[k]=[a[int((len(a)-1)*q)] for q in (.25,.5,.75)] if a else []
 groups=C.defaultdict(lambda:[[],[]])
 for x in closed:
  key=(x['window'],*[bisect.bisect_left(cuts[k],x['features']['z125'] if k=='z125' else x[k]) for k in cuts]);groups[key][int(x['id'] in ids)].append(x)
 weights=[(min(len(a),len(b)),sum(x['roundOutcome']=='negative' for x in b)/len(b)-sum(x['roundOutcome']=='negative' for x in a)/len(a)) for a,b in groups.values() if a and b];w=sum(a for a,b in weights);excluded=[x for x in parent if x['id'] not in ids]
 return dict(pairedReleaseN=len(paired),pairedReleaseMeanDelta=S.mean(paired) if paired else None,matchedWeight=w,adjustedNegativeRateDifference=sum(a*b for a,b in weights)/w if w else None,cuts=cuts,excludedCount=len(excluded),excludedOutcomes=dict(C.Counter(x['roundOutcome'] for x in excluded)),excludedReleaseMean=S.mean([x['delta'] for x in excluded if x['status']=='released']) if excluded else None)
def main():
 assert rd('audit.json')['passed'];xs=rd('event-profiles.json');market=rd('market-series.json');res={}
 for kind in ('H','L'):
  sub=[x for x in xs if x['kind']==kind];res[kind]={'all':out(sub)}
  for state in ('contraction','expansion'):
   hit=[x for x in sub if x['features'][state]];res[kind][state]=out(hit)
  for k in (125,250):
   # Explicitly distinguish normalized movement from raw moving-average change.
   res[kind][f'z{k}VsRawMean20']=dict(zRisesRawDoesNot=sum(x['features'][f'deltaZ{k}']>0 and x['features']['deltaMA20']<=0 for x in sub),zFallsRawDoesNot=sum(x['features'][f'deltaZ{k}']<0 and x['features']['deltaMA20']>=0 for x in sub))
 dates={x['date']:x['market'] for x in xs};states={}
 for p in market:
  states[p]={state:sorted(d for d,features in dates.items() if features[p].get(state,False)) for state in ('contraction','expansion')}
 overlaps={state:dict(stockMarketDates=len(dates),volume=len(states['market_volume'][state]),value=len(states['market_value'][state]),transactions=len(states['market_transaction'][state]),allThree=len(set(states['market_volume'][state])&set(states['market_value'][state])&set(states['market_transaction'][state]))) for state in ('contraction','expansion')}
 firstChecks={}
 for h in ('H1','H2','L1','L2'):
  rows=rd('paths/VRI-LT-'+h+'-full.json');first={}
  for x in sorted(rows,key=lambda x:x['entryDate']):first.setdefault(x['unit'],x)
  firstChecks[h]=dict(stockWindows=len(first),marketDates=len(set(x['entryDate'] for x in first.values())),hFallbackProvenAbsent=sum(x['lFallbackProvenAbsent'] for x in first.values()),allWaits=dict(C.Counter(x['wait'] for x in rows)),firstWaits=dict(C.Counter(x['wait'] for x in first.values())))
 # Compare the already predeclared temporal-only ablations; never generate masks.
 ma=rd('paths/VRI-LT-H1-temporal.json');z=rd('paths/VRI-LT-H2-temporal.json');price=rd('paths/VRI-LT-H2-price.json')
 ablations=dict(MA_vs_price=comparison(ma,price),MAZ_vs_price=comparison(z,price),MAZ_vs_MA=comparison(z,ma),MAZ_rawContrast=dict(n=len(z),rawMean20Falls=sum(x['features']['deltaMA20']<0 for x in z),rawMean60Falls=sum(x['features']['deltaMA60']<0 for x in z),singleDayZ125Range=[min(x['features']['z125'] for x in z),max(x['features']['z125'] for x in z)],allOpportunityMarkMean=S.mean(x['endOrReleaseMark'] for x in z)))
 result=dict(coverage=res,marketDateStateSensitivity=overlaps,marketDatesIndependentOfStockCount=True,firstChecks=firstChecks,predeclaredAblationComparisons=ablations,notTested=['125/250-session slopes','other lookback lengths or thresholds','Z125 minus Z250 candidate','market temporal gates','market value/transaction independent candidates','strategy replay'],strategyReplay=False)
 (O/'coverage-and-raw-contrast.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
