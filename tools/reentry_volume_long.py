#!/usr/bin/env python3
"""VRI-LT: four frozen temporal hypotheses; read-only inputs, no strategy replay."""
import bisect,collections as C,csv,datetime as D,json,math,statistics as S,sys,time
from pathlib import Path
import reentry_volume as base
R=base.R;O=R/'exports/vri-long-20261006';OLD=R/'exports/vri-p00-p03-20261005';V=base.V
base.O=O
def rd(p):return base.read(p)
def save(n,x):base.save(n,x)
def eq(a,b):assert math.isclose(a,b,rel_tol=1e-9,abs_tol=1e-6),(a,b)
def series(data):
 """Verify persisted MA, Z and restartable directional counts against raw volume."""
 result=[];values=[];counts=C.Counter()
 for i,a in enumerate(data):
  values.append(a['v']);recent=values[max(0,i-249):i+1][::-1]
  for k in (20,60):
   ma=sum(recent[:k])/len(recent[:k]);eq(ma,a[f'ma{k}'])
   # Formula checked first; direction must use the authoritative persisted MA
   # so 1e-14 summation differences cannot turn an exact tie into a reversal.
   ma=a[f'ma{k}']
   if not i:days=0
   else:
    prev=data[i-1];pd=prev[f'days{k}'];span=int(abs(pd));old=data[i-span-1][f'days{k}'] if 0<span<5 and i-span-1>=0 else 0
    if ma>prev[f'ma{k}']:days=(old+1 if pd> -5 and old>0 else 1) if pd<0 else pd+1
    elif ma<prev[f'ma{k}']:days=(old-1 if pd<5 and old<0 else -1) if pd>0 else pd-1
    else:days=pd+(1 if pd>0 else -1 if pd<0 else 0)
   eq(days,a[f'days{k}']);counts['maAndDays']+=2
  for k in (125,250):
   xs=recent[:k];mu=sum(xs)/len(xs);sd=math.sqrt(sum((x-mu)**2 for x in xs)/len(xs));z=(a['v']-mu)/sd if sd else 0;eq(z,a[f'z{k}']);counts['z']+=1
  f=dict(a,observations=i+1)
  if i>=288:
   f.update(deltaMA60=a['ma60']-data[i-20]['ma60'],deltaMA20=a['ma20']-data[i-20]['ma20'])
   for k in (125,250):
    current=S.mean(x[f'z{k}'] for x in data[i-19:i+1]);prior=S.mean(x[f'z{k}'] for x in data[i-39:i-19]);f[f'deltaZ{k}']=current-prior;f[f'meanZ{k}']=current
   f['contraction']=a['days60']<=-5 and f['deltaMA60']<0 and a['ma20']<a['ma60'] and 0<a['days20']<5
   f['expansion']=a['days60']>=5 and f['deltaMA60']>0 and a['ma20']>a['ma60'] and -5<a['days20']<0
  result.append(f)
 return result,counts
def extract():
 assert not (O/'extract-complete.json').exists();inv=base.preflight();source=rd(OLD/'source-hashes.json');source.update(rd(OLD/'source-hashes-analysis.json'))
 for name,d in source.items():assert base.sha(R/name)==d,name
 save('reused-source-verification.json',dict(hashes=source,allMatched=True))
 assert rd(OLD/'audit.json')['passed'];segments=rd(OLD/'segments.json');assert len(segments)==3597
 mp=R/'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af';tech=base.csvmap(mp/'market-technical.csv');raw=base.csvmap(mp/'market-daily.csv');md=sorted(tech);market={};checks=C.Counter();qualities=C.Counter()
 for pref,col in [('market_volume','volume_lots'),('market_value','trade_value'),('market_transaction','transaction_count')]:
  data=[dict(date=d,v=float(raw[d][col]),**{f'ma{k}':float(tech[d][f'{pref}_ma_{k}']) for k in (20,60)},**{f'days{k}':float(tech[d][f'{pref}_ma_{k}_days']) for k in (20,60)},**{f'z{k}':float(tech[d][f'{pref}_z_{k}']) for k in (125,250)}) for d in md]
  vals,ct=series(data);market[pref]={str(a['date']):a for a in vals};checks.update(ct)
 save('market-series.json',market)
 for sample,iv in inv.items():
  for w,fn in enumerate(('browse.store','period-20200722.store','period-20230722.store'),1):
   with base.db(R/iv['report']/fn) as c:
    for st in c.execute('select * from ZSTOCK'):
     uid=f'{sample}-{w}-{st["ZSID"]}';u=rd(V/'units'/(uid+'.json'));raw=list(c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],)));data=[]
     for a in raw:
      if a['ZDATASOURCE']=='TWSE' and math.isfinite(a['ZVOLUMECLOSE']) and a['ZVOLUMECLOSE']>=0:
       data.append(dict(date=base.day(a['ZDATETIME']),v=a['ZVOLUMECLOSE'],**{f'ma{k}':a[f'ZVMA{k}'] for k in (20,60)},**{f'days{k}':a[f'ZVMA{k}DAYS'] for k in (20,60)},**{f'z{k}':a[f'ZVZ{k}'] for k in (125,250)}))
     vals,ct=series(data);checks.update(ct);dates=[a['date'] for a in vals];out=[]
     for r in u['rows']:
      j=bisect.bisect_left(dates,r['date'])-1;m=md[bisect.bisect_left(md,r['date'])-1];f=vals[j];assert dates[j]==r['stockVolumeDate'] and m==r['marketVolumeDate'] and f['date']<r['date'];q=list(r['quality'])
      if f['observations']<289 or market['market_volume'][str(m)]['observations']<289:q.append('LT289Warmup')
      if not q:assert dates[j-39]<dates[j-20]<dates[j]<r['date'];checks['timeline']+=1
      qualities.update(q);out.append(dict(date=r['date'],quality=q,stock=f,marketDate=m))
     save('units/'+uid+'.json',out);base.progress('LT-extract',unit=uid,checked=checks['timeline'])
 save('source-hashes.json',base.HASH);save('extract-complete.json',dict(checks=checks,qualityReasons=qualities,units=150,motherSegments=3597,reentries=3583,resources=base.usage(),strategyReplay=False))
HS=[dict(id='VRI-LT-'+x,kind=x[0],z=x.endswith('2')) for x in ('H1','H2','L1','L2')]
def predicate(h,variant,r,s,a):
 if a['quality']:return False
 f=a['stock'];P=(r['price']>s['sellPrice'] and r['features']['d20']>0) if h['kind']=='H' else (r['price']<=s['sellPrice'] and r['features']['d20']<0)
 single=(f['z125']>1 and f['v']>f['ma20']) if h['kind']=='H' else (f['z125']<0 and f['v']<f['ma20'])
 if h['kind']=='H':temporal=f['contraction'] and (not h['z'] or (f['deltaZ125']<=0 and f['deltaZ250']<=0))
 else:temporal=not (f['expansion'] and (not h['z'] or (f['deltaZ125']>=0 and f['deltaZ250']>=0)))
 return P and (variant in ('price','temporal') or single) and (variant in ('price','single') or temporal)
def summary(xs):
 rel=[x for x in xs if x['status']=='released'];ds=[x['delta'] for x in rel];date=C.defaultdict(list);stock=C.defaultdict(list)
 for x in rel:date[x['entryDate']].append(x['delta']);stock[x['stock']].append(x['delta'])
 def drop(g):
  if len(g)<2:return None
  k=min(g,key=lambda k:sum(g[k]));return dict(removed=k,mean=base.mean([a for z,vs in g.items() if z!=k for a in vs]))
 return dict(n=len(xs),outcomes=dict(C.Counter(x['roundOutcome'] for x in xs)),status=dict(C.Counter(x['status'] for x in xs)),lower=sum(a< -1e-8 for a in ds),higher=sum(a>1e-8 for a in ds),same=sum(abs(a)<=1e-8 for a in ds),mean=base.mean(ds),median=base.med(ds),unreleasedOutcomes=dict(C.Counter(x['roundOutcome'] for x in xs if x['status']!='released')),maxRise=max([x['maxRise'] for x in xs],default=None),dateCount=len(set(x['entryDate'] for x in xs)),dateMean=base.mean([S.mean(v) for v in date.values()]),dropBestStock=drop(stock),dropBestDate=drop(date),bySample={s:dict(n=len(a:=[x for x in rel if x['sample']==s]),mean=base.mean([x['delta'] for x in a])) for s in 'ABCDE'},byWindow={str(w):dict(n=len(a:=[x for x in rel if x['window']==w]),mean=base.mean([x['delta'] for x in a])) for w in (1,2,3)})
def evaluate():
 assert not (O/'evaluation-complete.json').exists();assert (O/'extract-complete.json').exists();segs=rd(OLD/'segments.json');by=C.defaultdict(list)
 for s in segs:by[s['unit']].append(s)
 paths={h['id']:{v:[] for v in ('price','single','temporal','full')} for h in HS};first=[];market=rd(O/'market-series.json');profiles=[]
 save('hypotheses-frozen.json',dict(hypotheses=HS,period=20,zBlockLength=20,volumeMaturity=289,directionResetBoundary=5,variants=['price','single','temporal','full']))
 for uid,ss in by.items():
  rows=rd(V/'units'/(uid+'.json'))['rows'];ls=rd(O/'units'/(uid+'.json'));assert len(rows)==len(ls)
  for s in ss:
   if s['entryIndex'] is not None and not ls[s['entryIndex']]['quality']:
    a=ls[s['entryIndex']];profiles.append(dict(id=s['id'],kind=s['entryRule'],outcome=s['roundOutcome'],sample=s['sample'],window=s['window'],stock=s['stock'],date=s['entryDate'],features=a['stock'],market={k:market[k][str(a['marketDate'])] for k in market}))
   for h in HS:
    for variant,out in paths[h['id']].items():
     ix=[i for i in s['flatIndices'] if predicate(h,variant,rows[i],s,ls[i])]
     executable=s.get('entryRule')==h['kind'] and s['entryIndex'] in ix
     if ix:first.append(dict(hypothesis=h['id'],variant=variant,segment=s['id'],firstCondition=rows[ix[0]]['date'],conditionDays=len(ix),firstExecutable=s['entryDate'] if executable else None))
     if not executable:continue
     i=s['entryIndex'];end=s['roundEndIndex'] if s['roundEndIndex'] is not None else len(rows)-1
     j=next((j for j in range(i+1,end+1) if not predicate(h,variant,rows[j],s,ls[j])),None);q=j if j is not None else end
     status='released' if j is not None else 'originalExitBlocked' if s['roundEndIndex'] is not None else 'censored'
     if j is not None and ls[j]['quality']:status='qualityFailOpen'
     x={k:s[k] for k in ('id','unit','stock','sample','window','entryDate','entryPrice','entryRule','roundOutcome','roundProfit','flatTradingDays','entryRelativeSellPct','lFallbackProvenAbsent')}
     x.update(hypothesis=h['id'],variant=variant,status=status,releaseDate=rows[j]['date'] if j is not None else None,delta=100*(rows[q]['price']/s['entryPrice']-1) if j is not None else None,endOrReleaseMark=100*(rows[q]['price']/s['entryPrice']-1),wait=rows[q]['index']-rows[i]['index'],maxRise=max([100*(r['price']/s['entryPrice']-1) for r in rows[i+1:q+1]],default=0),minFall=min([100*(r['price']/s['entryPrice']-1) for r in rows[i+1:q+1]],default=0),features=ls[i]['stock'],candidateEligibilityAfterDivergence='unknown')
     out.append(x)
  base.progress('LT-evaluate',unit=uid)
 results=[]
 for h in HS:
  pp=paths[h['id']];info={}
  for v,xs in pp.items():
   save(f'paths/{h["id"]}-{v}.json',xs);ff={}
   for x in sorted(xs,key=lambda x:x['entryDate']):ff.setdefault(x['unit'],x)
   info[v]=dict(all=summary(xs),first=summary(list(ff.values())))
  full=pp['full'];single=pp['single'];sm={x['id']:x for x in single};ids={x['id'] for x in full};paired=[x['delta']-sm[x['id']]['delta'] for x in full if x['status']=='released' and sm[x['id']]['status']=='released']
  rescued=[x for x in full if x['status']=='released' and sm[x['id']]['status']!='released'];protected=[x for x in single if x['id'] not in ids]
  closed=[x for x in single if x['roundOutcome'] in ('positive','negative','neutral')];cuts={}
  for k in ('flatTradingDays','entryRelativeSellPct','z125'):
   a=sorted(x['features']['z125'] if k=='z125' else x[k] for x in closed);cuts[k]=[a[int((len(a)-1)*p)] for p in (.25,.5,.75)] if a else []
  groups=C.defaultdict(lambda:[[],[]])
  for x in closed:
   key=(x['window'],*[bisect.bisect_left(cuts[k],x['features']['z125'] if k=='z125' else x[k]) for k in cuts]);groups[key][int(x['id'] in ids)].append(x)
  pairs=[(min(len(a),len(b)),sum(x['roundOutcome']=='negative' for x in b)/len(b)-sum(x['roundOutcome']=='negative' for x in a)/len(a)) for a,b in groups.values() if a and b];weight=sum(w for w,d in pairs)
  results.append(dict(hypothesis=h,variants=info,pairedFullMinusSingle=dict(n=len(paired),mean=base.mean(paired)),rescued=summary(rescued),excludedFromSingle=summary(protected),adjustedNegativeRate=dict(weight=weight,difference=sum(w*d for w,d in pairs)/weight if weight else None,cuts=cuts),allOpportunityMarkMean=base.mean([x['endOrReleaseMark'] for x in full])))
 save('screening.json',results);save('first-condition-and-executable.json',first);save('event-profiles.json',profiles);save('analysis-source-hashes.json',base.HASH);save('evaluation-complete.json',dict(hypotheses=4,masks=16,firstRecords=len(first),qualifiedReentries=len(profiles),resources=base.usage(),strategyReplay=False))
if __name__=='__main__':
 try:{'extract':extract,'evaluate':evaluate}[sys.argv[1]]()
 except Exception as e:save('failure-'+str(int(time.time()))+'.json',dict(stage=sys.argv[1:],error=repr(e),resources=base.usage()));raise
