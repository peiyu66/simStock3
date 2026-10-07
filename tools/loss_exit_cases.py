#!/usr/bin/env python3
"""Case-first LC-P02-C. No atom pool import/use, replay, build or download."""
import os
for k in ('OMP_NUM_THREADS','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS','VECLIB_MAXIMUM_THREADS','NUMEXPR_NUM_THREADS'):os.environ[k]='1'
import json,math,time,resource,collections as C,hashlib,subprocess
from pathlib import Path
import numpy as np
import loss_exit_p01 as p
O=p.R/'exports/loss-exit-cases-20261002';START=time.monotonic();CPU=time.process_time()
resource.setrlimit(resource.RLIMIT_CPU,(600,600))
def read(n):return json.loads((O/n).read_text())
def save(n,v):
 q=O/n;t=q.with_suffix('.tmp');t.write_text(json.dumps(v,ensure_ascii=False,allow_nan=False,separators=(',',':'))+'\n');t.replace(q)
def usage():return dict(wallSeconds=time.monotonic()-START,cpuSeconds=time.process_time()-CPU,peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,allocatedBytes=sum(q.stat().st_blocks*512 for q in O.rglob('*') if q.is_file()))
def finish(stage,extra={}):
 u=usage();prev=sum(read('usage-'+q+'.json')['cpuSeconds'] for q in ('overview','evaluate','audit') if q!=stage and (O/('usage-'+q+'.json')).exists());assert u['cpuSeconds']+prev<600 and u['peakRSSBytes']<=512*1024**2 and u['allocatedBytes']<=64*1024**2,u;save('usage-'+stage+'.json',u);print(json.dumps(dict(stage=stage,resources=u,**extra)),flush=True)
def init():
 cat,X,meta,units=p.load_units();events=json.loads((p.O/'labels.json').read_text());names=[c['name'] for c in cat];assert len(events)==219 and sum(e['window']<3 for e in events)==156
 return cat,X,meta,units,events,names
def finite(xs):return [float(x) for x in xs if math.isfinite(x)]
def med(xs):
 xs=finite(xs);return float(np.median(xs)) if xs else None
def overview():
 cat,X,meta,units,events,names=init();ev=[e for e in events if e['window']<3];out=[]
 save('protocol.json',dict(planCommit='35c7d26cf041a75fde71370124f23bdf76b07ad7',authorization='使用者：好，請繼續推進；最多6機制4假說，案例先行',sourceTask='01a0f6bf-257a-715e-afc9-d8d2f5b61028',discoveryEvents=156,discoveryWindows=[1,2],frozenCheckWindow=3,maxMechanisms=6,maxHypotheses=4,limits=dict(CPU=1,RSS=512*1024**2,newFiles=64*1024**2,CPUSeconds=600,builds=0,strategyRuns=0,downloads=0),inputHashes={n:p.sha(p.O/n) for n in ('labels.json','feature-catalog.json','extraction.json','source-hashes.json')},worktreeBefore={s[3:]:p.sha(p.R/s[3:]) for s in subprocess.check_output(['git','status','--porcelain','-z'],text=True).split('\0') if s and (p.R/s[3:]).is_file()}))
 for j,c in enumerate(cat):
  if c['group']=='S':continue
  stats={}
  for side in ('early','late'):
   diffs=[];gm=[];bm=[];om=[];originGood=[];originBad=[];missing=0;paired=0
   for e in ev:
    d=e['sides'][side]
    if not d['qualityEligible']:continue
    orig=X[e['index'],j];pairs=[(i,100*(meta[i][3]['price']/e['price']-1)) for i in d['indices']];good=[X[i,j] for i,ret in pairs if ret>1e-10];bad=[X[i,j] for i,ret in pairs if ret< -1e-10];g=med(good);b=med(bad);o=clean(orig);missing+=sum(not math.isfinite(X[i,j]) for i,_ in pairs)
    if g is not None:gm.append(g)
    if b is not None:bm.append(b)
    if o is not None:om.append(o)
    if g is not None and b is not None:diffs.append(g-b);paired+=1
    if o is not None:(originGood if any(ret>0 for _,ret in pairs) else originBad).append(o)
   stats[side]=dict(goodDayEventMedian=med(gm),badDayEventMedian=med(bm),originMedian=med(om),pairedEvents=paired,withinEventMedianDifference=med(diffs),positiveContrastEvents=sum(d>0 for d in diffs),negativeContrastEvents=sum(d<0 for d in diffs),missingLinks=missing,originAnyHigherMedian=med(originGood),originNoHigherMedian=med(originBad),originAnyHigherEvents=len(originGood),originNoHigherEvents=len(originBad))
  out.append(dict(name=c['name'],group=c['group'],kind=c['kind'],stats=stats))
 save('single-factor-descriptive.json',out)
 # This stage describes values only. No threshold fitting, pair creation or W3 outcome reading.
 finish('overview',dict(fields=len(out)))
def clean(v):return float(v) if math.isfinite(v) else None
if __name__=='__main__':overview()

def term(a,row,names):
 v=float(row[names.index(a[0])]);return (v>a[2] if a[1]=='gt' else v<a[2]) if math.isfinite(v) else None

def evaluate():
 cat,X,meta,units,events,names=init();frozen=read('hypotheses-frozen.json');assert len(frozen['hypotheses'])<=4;cards=[]
 marketdays=sorted(p.prior.market_inputs()[1]);mi={d:i for i,d in enumerate(marketdays)}
 evmap={(e['sample'],e['window'],e['stock'],e['round']):e for e in events};rounds=C.defaultdict(list)
 for i,(s,w,stock,r) in enumerate(meta):
  if r['held']:rounds[(s,w,stock,r['round'])].append(i)
 def blockers(i):
  r=meta[i][3];g=r['gates'];v=lambda n:X[i,names.index(n)]
  e1=(not g['base'] and -.97<v('market_high_diff_z_250')<.83 and v('tOscMax9')<0 and (v('delta_osc_z125')<.22 or v('delta_market_osc_z_125')>0) and (r['grade']>=1 or v('intraday_low_diff')>-.53))
  e2=(v('market_ma_20_diff_max_9')<1.2 and v('market_phase') in (2,3) and (v('priceHigh')!=v('tHighMax9') or v('market_low_diff_z_125')<0))
  # Mature technical inputs are required; missing values never synthesize a block.
  if not all(math.isfinite(v(n)) for n in ('market_high_diff_z_250','tOscMax9','delta_osc_z125','delta_market_osc_z_125')):e1=False
  if not all(math.isfinite(v(n)) for n in ('market_ma_20_diff_max_9','market_low_diff_z_125','priceHigh','tHighMax9','market_phase','osc_z125')):e2=False
  return bool(e1),bool(e2)
 for h in frozen['hypotheses']:
  mask=[];unknown=[]
  for row in X:
   a,b=[term(t,row,names) for t in h['terms']];unknown.append(a is None or b is None);mask.append(a is True and b is True)
  records=[];roundRecords=[]
  if h['direction']=='early':
   effective=[]
   for i,(_,_,_,r) in enumerate(meta):
    if not r['held']:effective.append(False);continue
    e1,e2=blockers(i);effective.append(bool(mask[i] and not r['quality'] and not r['gates']['normalSell'] and not e1 and not e2))
   for e in events:
    indices=e['sides']['early']['indices'];hits=[i for i in indices if effective[i]];allhits=[i for i in indices if mask[i]];first=hits[0] if hits else None
    rec=dict(sample=e['sample'],window=e['window'],stock=e['stock'],origin=e['date'],round=e['round'],qualified=e['sides']['early']['qualityEligible'],rawConditionDays=len(allhits),effectiveDays=len(hits),unknownDays=sum(unknown[i] for i in indices),actionDate=meta[first][3]['date'] if first is not None else None,priceDeltaPct=100*(meta[first][3]['price']/e['price']-1) if first is not None else None,ownRouteKnown=False)
    if first is not None:rec.update(actionValues={t[0]:float(X[first,names.index(t[0])]) for t in h['terms']},actionNet=meta[first][3]['gates']['net'],baselineNet=e['profit'],sameQuantity=meta[first][3]['qtyBefore']==meta[e['index']][3]['qtyBefore'],grade=meta[first][3]['grade'])
    records.append(rec)
   for key,indices in rounds.items():
    hits=[i for i in indices if effective[i]]
    if not hits:continue
    i=hits[0];r=meta[i][3];last=meta[indices[-1]][3];ev=evmap.get(key);within=bool(ev and i in ev['sides']['early']['indices'])
    roundRecords.append(dict(sample=key[0],window=key[1],stock=key[2],round=key[3],firstDate=r['date'],hits=len(hits),withinOriginalLossWindow=within,originalOutcome='unclosed' if not last['qtySell'] else 'loss' if last['profit']<0 else 'nonloss',originalExitDate=last['date'] if last['qtySell'] else None,firstPrice=r['price'],originalExitPrice=last['price'] if last['qtySell'] else None,firstPriceDeltaPct=100*(r['price']/last['price']-1) if last['qtySell'] else None,firstGrade=r['grade'],firstNet=r['gates']['net'],sameQuantity=r['qtyBefore']==last['qtyBefore']))
   legal=sum(r['held'] and not r['quality'] for _,_,_,r in meta);extra=dict(legalHoldingDays=legal,rawHeldConditionDays=sum(mask[i] and r['held'] for i,(_,_,_,r) in enumerate(meta)),effectiveExtraDays=sum(effective),rounds=roundRecords,blockedByExistingExclusions=sum(mask[i] and r['held'] and not r['gates']['normalSell'] and any(blockers(i)) for i,(_,_,_,r) in enumerate(meta)))
  else:
   for e in events:
    idx=e['index'];r=meta[idx][3];trigger=bool(mask[idx] and r['gates']['lateEligible'] and not r['quality']);d=e['sides']['late'];release=None;reason=None
    if trigger:
     for i in d['indices']:
      rr=meta[i][3];distance=mi[rr['date']]-mi[r['date']]
      if distance>=10 or unknown[i] or not mask[i]:release=i;reason='marketDayLimit' if distance>=10 else 'missingCondition' if unknown[i] else 'conditionReleased';break
    rec=dict(sample=e['sample'],window=e['window'],stock=e['stock'],origin=e['date'],round=e['round'],qualified=d['qualityEligible'],trigger=trigger,originUnknown=unknown[idx],originValues={t[0]:clean(X[idx,names.index(t[0])]) for t in h['terms']},observedHigher=d['observedHigher'],releaseDate=meta[release][3]['date'] if release is not None else None,releaseReason=reason,priceDeltaPct=100*(meta[release][3]['price']/e['price']-1) if release is not None else None,marketDays=mi[meta[release][3]['date']]-mi[e['date']] if release is not None else None,grade=r['grade'],candidateOwnS='unknown',actualSell='unknown',baselineNet=e['profit'])
    records.append(rec)
   extra=dict(ownSUsedAfterExit=False,releaseIsActualSale=False)
  summary={}
  for group,ws in [('discovery',(1,2)),('frozenW3',(3,))]:
   rr=[r for r in records if r['window'] in ws];hit=[r for r in rr if (r.get('actionDate') is not None if h['direction']=='early' else r['trigger'])];valid=[r for r in hit if r['qualified'] and r['priceDeltaPct'] is not None];pos=[r for r in valid if r['priceDeltaPct']>1e-10];neg=[r for r in valid if r['priceDeltaPct']< -1e-10];zero=[r for r in valid if abs(r['priceDeltaPct'])<=1e-10]
   bystock=C.Counter(r['stock'] for r in pos);bywindow=C.Counter(str(r['window']) for r in pos)
   summary[group]=dict(events=len(rr),hitEvents=len(hit),priceComparable=len(valid),higher=len(pos),lower=len(neg),same=len(zero),unknown=len(hit)-len(valid),medianPriceDeltaPct=med([r['priceDeltaPct'] for r in valid]),worstPriceDeltaPct=min([r['priceDeltaPct'] for r in valid],default=None),bestPriceDeltaPct=max([r['priceDeltaPct'] for r in valid],default=None),positiveStocks=dict(bystock),positiveWindows=dict(bywindow),positiveGrades=dict(C.Counter(str(r['grade']) for r in pos)),minimumCoverageMet=len(pos)>=3 and len(bystock)>=2 and (len(bywindow)==2 if group=='discovery' else True),withoutLargestPositiveStockHigher=len(pos)-max(bystock.values(),default=0))
  cards.append(dict(hypothesis=h,summary=summary,eventRecords=records,**extra));save('checkpoint.json',dict(completedHypotheses=[c['hypothesis']['id'] for c in cards],frozenSHA256=p.sha(O/'hypotheses-frozen.json')))
  print(h['id'],json.dumps(summary),flush=True)
 save('candidate-cards.json',cards);finish('evaluate',dict(hypotheses=len(cards)))
