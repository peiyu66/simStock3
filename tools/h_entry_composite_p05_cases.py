#!/usr/bin/env python3
"""Bounded counterexamples and stopped-rule first-divergence overlap."""
import numpy as np
import h_entry_composite_p05 as w
q,p,r,v,h,O=w.q,w.p,w.r,w.v,w.h,w.O

def fill(x,limit=10):return x['hit']and x['wait']is not None and x['wait']<=limit and not x['afterExit']and not x['missing']
def positive(x):return fill(x)and x['saving']>0
def negative(x):return fill(x)and x['saving']<0
def samefill(a,b):return b['hit']and all(a[k]==b[k]for k in ('wait','fillDate','lFill','saving','afterExit','early','missing'))
def main():
 assert not(O/'cases.json').exists();data=w.read(O/'analysis.json');defs=w.read(p.P/'atoms-no-outcome-ranking.json');cat=w.read(p.P/'feature-catalog.json');hist={x:v.inputs(defs,x)for x in ('discovery','later')};old05path=w.R/'exports/h-entry-composite-p305-diagnosis-20260929/matched-rounds.json';old05=w.read(old05path);keys={}
 for label,(dd,X,C)in hist.items():
  keys.update({(k['sample'],k['window'],k['stock'],k['date']):(label,i)for i,k in enumerate(dd[0])})
 out=[]
 for n in data['candidates']:
  own=sum((x['knownFlatDetails']for x in n['historical'].values()),[]);base=sum((x['baselineDetails']for x in n['historical'].values()),[]);good={x['id']:x for x in own if positive(x)};bad={x['id']:x for x in own if negative(x)};goodbycell={c:{k for k,x in good.items()if x['sample']+str(x['window'])==c}for c in ('A1','A2','A3','B1','B2','B3')};badbycell={c:{k for k,x in bad.items()if x['sample']+str(x['window'])==c}for c in goodbycell};masks={label:r.evaluate(n['expr'],dd[0][2])[0]for label,dd in hist.items()};matches=[]
  for x in old05:
   win={20170722:1,20200722:2,20230722:3}[x['start']];label,i=keys[x['sample'],win,x['stock'],x['date']];matches.append(dict(**x,newFormulaHit=bool(masks[label][i])))
  diagnose=[]
  for spec in n['variants']:
   ov=[]
   for label,(dd,X,C)in hist.items():
    dd=v.changed_data(dd,X,C,defs,cat,spec);bb,oo=r.details(spec['expr'],dd);ov+=oo
   byid={x['id']:x for x in ov};retainedgood={k for k,x in good.items()if samefill(x,byid[k])};retainedbad={k for k in bad if byid[k]['hit']};newbad={x['id']for x in ov if negative(x)};newgood={x['id']for x in ov if positive(x)}
   diagnose.append(dict(kind=spec['kind'],field=spec['field'],value=spec.get('value'),badExcluded=sorted(set(bad)-retainedbad),goodOriginalFillChanged=sorted(set(good)-retainedgood),goodNoLongerCheaper=sorted(set(good)-newgood),goodStillCheaper=len(set(good)&newgood),knownGoodNew=len(newgood),knownBadNew=len(newbad),newDearerCases=sorted(newbad-set(bad)),allOriginalGoodFillPreserved=len(retainedgood)==len(good),allOriginalBadEntryExcluded=not retainedbad,badTransitions=[dict(id=k,before=dict(wait=x['wait'],saving=x['saving'],afterExit=x['afterExit']),after={f:byid[k][f]for f in ('hit','wait','saving','afterExit','missing','fillDate')})for k,x in bad.items()],cells={c:dict(badExcluded=len(badbycell[c]-retainedbad),badTotal=len(badbycell[c]),goodFillChanged=len(goodbycell[c]-retainedgood),goodTotal=len(goodbycell[c]))for c in goodbycell}))
  horizons={}
  for limit in (3,5,10):
   fills=[x for x in own if fill(x,limit)];horizons[limit]=dict(knownFills=len(fills),cheaper=sum(x['saving']>0 for x in fills),dearer=sum(x['saving']<0 for x in fills),equal=sum(x['saving']==0 for x in fills),meanSaving=float(np.mean([x['saving']for x in fills]))if fills else None,medianSaving=float(np.median([x['saving']for x in fills]))if fills else None,medianWait=float(np.median([x['wait']for x in fills]))if fills else None)
  hit=[x for x in matches if x['newFormulaHit']];out.append(dict(id=n['id'],historicalHorizons=horizons,knownGood=list(good.values()),knownBad=list(bad.values()),variants=diagnose,strictRepairCount=sum(x['allOriginalGoodFillPreserved']and x['allOriginalBadEntryExcluded']and x['knownBadNew']==0 for x in diagnose),partialRepairCount=sum(x['allOriginalGoodFillPreserved']and len(x['badExcluded'])>0 and x['knownBadNew']<len(bad)for x in diagnose),stopped05Overlap=dict(hit=len(hit),all=60,stockWindowEfficiencyNegative=sum(x['stockEfficiencyDelta']<0 for x in hit),stockWindowEfficiencyPositive=sum(x['stockEfficiencyDelta']>0 for x in hit),firstFillCheaper=sum(x['savingPct']>0 for x in hit),firstFillDearer=sum(x['savingPct']<0 for x in hit),cases=matches)))
  print(n['id'],horizons[10],'repair',out[-1]['strictRepairCount'],out[-1]['partialRepairCount'],'old05',out[-1]['stopped05Overlap']['hit'],flush=True)
 w.save('cases.json',dict(scope='Historical v33 observed paths only; one-at-a-time diagnostics, no candidate reselection; same first fill is not full-strategy path preservation',source05SHA=p.sha(old05path),candidates=out))
if __name__=='__main__':main()
