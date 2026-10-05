#!/usr/bin/env python3
"""VRI fixed nine-hypothesis observational batch. Never executes simUpdate."""
import bisect,collections as C,csv,datetime as D,hashlib,json,math,resource,sqlite3,statistics as S,subprocess,sys,time
from pathlib import Path
R=Path(__file__).resolve().parents[1]; O=R/'exports/vri-p00-p03-20261005'; V=R/'exports/vcx-p01-p04-20261005'
RULE='7ba8447fbf207484ab305cad0c6beca216da8c93'; STRATEGY='s49-sell-delay-f03-r1-20261001'
START=time.monotonic(); CPU=time.process_time(); HASH={}
resource.setrlimit(resource.RLIMIT_CPU,(900,900))
def sha(p):
 h=hashlib.sha256()
 with Path(p).open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def src(p):
 p=Path(p); HASH[str(p.relative_to(R))]=sha(p);return p
def read(p):return json.loads(src(p).read_text())
def save(n,x):
 p=O/n;p.parent.mkdir(parents=True,exist_ok=True);t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(x,ensure_ascii=False,allow_nan=False,indent=2)+'\n');t.replace(p)
def usage():return dict(wallSeconds=time.monotonic()-START,cpuSeconds=time.process_time()-CPU,peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,allocatedBytes=sum(p.stat().st_blocks*512 for p in O.rglob('*') if p.is_file()))
def progress(stage,**kw):
 u=usage();assert u['wallSeconds']<900 and u['peakRSSBytes']<1073741824 and u['allocatedBytes']<1073741824,u
 save('status.json',dict(stage=stage,**kw,resources=u));print(stage,kw,flush=True)
def db(p):
 src(p)
 wal=Path(str(p)+'-wal');assert not wal.exists() or wal.stat().st_size==0,p
 c=sqlite3.connect(p.as_uri()+'?mode=ro&immutable=1',uri=True);c.row_factory=sqlite3.Row
 assert c.execute('pragma quick_check').fetchone()[0]=='ok';return c
def day(t):return int((D.datetime(2001,1,1)+D.timedelta(seconds=t,hours=8)).strftime('%Y%m%d'))
def calendar(a,b):return (D.datetime.strptime(str(a),'%Y%m%d')-D.datetime.strptime(str(b),'%Y%m%d')).days
def eq(a,b):assert math.isclose(a,b,abs_tol=1e-6,rel_tol=1e-10),(a,b)
def mean(xs):return S.mean(xs) if xs else None
def med(xs):return S.median(xs) if xs else None
def sign(x):return 'positive' if x>1e-6 else 'negative' if x< -1e-6 else 'neutral'
def csvmap(p):
 with src(p).open(encoding='utf-8-sig') as f:return {int(x['date'].replace('-','')):x for x in csv.DictReader(f)}
def preflight():
 assert subprocess.check_output(['git','rev-parse',RULE+'^{commit}'],cwd=R,text=True).strip()==RULE
 inv=read(V/'inventory.json'); common=dict(ruleCommit=RULE,ruleVersion=STRATEGY,dataRuleVersion='T3/S61',through='2026/07/22',moneyBaseWan=600,automaticInvestments=2)
 for s,v in inv.items():
  for k in ('report','decisionBase'):
   p=R/v[k];m=read(p/'manifest.json')
   for key,value in dict(common,sampleID=s).items():assert m[key]==value,(p,key)
   assert src(p/'.complete').read_text().strip()==m.get('runID',m.get('decisionBaseID'))
  with db(R/v['decisionBase']/'decisions.sqlite') as c:
   meta=dict(c.execute('select * from metadata'))
   for k in ('ruleCommit','ruleVersion','dataRuleVersion','through'):assert meta[k]==common[k]
   assert meta['formatVersion']=='6'
  read(R/v['report']/'baseline.json');src(R/v['report']/'periods.csv')
 changes={}
 for n in ('technical.swift','RollingContext.swift','dataModel.swift','InternalBacktestDecisionBase.swift','SellDelayF01Rule.swift','SellDelayF03Rule.swift','HEntryDelayRule.swift','HEntryIncrementalDelayRule.swift','PullbackProfitSellRule.swift'):
  p=src(R/'simStock3'/n);frozen=subprocess.check_output(['git','show',RULE+':simStock3/'+n],cwd=R)
  if p.read_bytes()!=frozen:
   assert n=='technical.swift';anchor=b'    private func tUpdate('
   assert p.read_bytes().split(anchor,1)[1]==frozen.split(anchor,1)[1];changes[n]='tUpdate and subsequent simulation byte-identical; prior download/cache code differs'
 save('preflight.json',dict(identity=common,inventory=inv,sourceCompatibility=changes,head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),strategyReplay=False))
 return inv

def extract():
 assert not (O/'extraction-complete.json').exists()
 inv=preflight();market=csvmap(R/'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af/market-technical.csv');mdates=sorted(market)
 allseg=[];total=C.Counter(); audit=C.Counter()
 for sample,iv in inv.items():
  with db(R/iv['decisionBase']/'decisions.sqlite') as c:
   events={(x['window_id'],x['stock_id'],x['trade_date']):dict(x) for x in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=1')}
  for w,fn in enumerate(('browse.store','period-20200722.store','period-20230722.store'),1):
   p=R/iv['report']/fn
   with db(p) as c:
    stocks=list(c.execute('select * from ZSTOCK'));assert len(stocks)==10
    for st in stocks:
     assert st['ZTECHNICALSTATEVERSION']==3 and st['ZSIMULATIONSTATEVERSION']==61
     assert st['ZTECHNICALDIRTYFROM'] is None and st['ZSIMULATIONDIRTYFROM'] is None
     uid=f'{sample}-{w}-{st["ZSID"]}';u=read(V/'units'/f'{uid}.json');rows=u['rows']
     assert u['identity']['store']==HASH[str(p.relative_to(R))] and u['identity']['base']==HASH[str((R/iv['decisionBase']/'decisions.sqlite').relative_to(R))]
     raw=[dict(x) for x in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],))]; ix={day(x['ZDATETIME']):i for i,x in enumerate(raw)}
     assert len(ix)==len(raw)
     for r in rows:
      i=ix[r['date']];rr=raw[i];prev=raw[i-1];pp=raw[i-2];f=r['features'];e=events[(w,st['ZSID'],r['date'])]
      assert not rr['ZSIMREVERSED'] and not rr['ZSIMINVESTBYUSER'] and rr['ZDATASOURCE']=='TWSE'
      assert r['stockVolumeDate']==day(prev['ZDATETIME'])<r['date']
      mi=bisect.bisect_left(mdates,r['date']);md=mdates[mi-1];assert md==r['marketVolumeDate']<r['date'];mv=market[md];mc=market[r['date']]
      for name,col in [('svz','ZVZ125'),('sv20','ZVMA20DIFF'),('sv60','ZVMA60DIFF')]:eq(f[name],prev[col])
      eq(f['dsvz'],prev['ZVZ125']-pp['ZVZ125']);eq(f['ma20'],rr['ZTMA20DIFF']);eq(f['d20'],rr['ZTMA20DIFF']-prev['ZTMA20DIFF'])
      eq(f['m20'],float(mc['market_ma_20_diff']))
      for pref,out in [('market_volume','mvz'),('market_value','valuez'),('market_transaction','transz')]:eq(f[out],float(mv[pref+'_z_125']))
      eq(r['qtyBefore'],e['inventory_before']);eq(r['qtyBefore'],prev['ZSIMQTYINVENTORY']);eq(r['price'],rr['ZPRICECLOSE']);eq(r['qtyBuy'],rr['ZSIMQTYBUY']);eq(r['qtySell'],rr['ZSIMQTYSELL'])
      if r['flat']:assert (r['hDelay'] or r['lDelay'])==(r['qtyBuy']>0)
      assert r['date']<=int((20200722,20230722,20260722)[w-1]);audit['independentRawDayChecks']+=1
     # Use observed actual trades to create intervals; never recompute strategy.
     seg=None;initial=True;unitseg=[]
     for i,r in enumerate(rows):
      total['decisionDays']+=1
      if r['flat']:
       total['flatDays']+=1
       if initial:total['initialFlatDays']+=1
       else:
        assert seg is not None;seg['flatIndices'].append(i);total['postSellFlatDays']+=1
       if r['qtyBuy']>0:
        total['allEntries']+=1
        if initial:total['initialEntries']+=1
        else:
         seg['entryIndex']=i;seg['entryDate']=r['date'];seg['entryRule']=r['buyRule'];seg['entryPrice']=r['price'];seg['entryRelativeSellPct']=100*(r['price']/seg['sellPrice']-1);seg['flatTradingDays']=r['index']-seg['sellIndex'];seg['flatCalendarDays']=calendar(r['date'],seg['sellDate']);seg['quality']=r['quality']
         end=next((j for j in range(i+1,len(rows)) if rows[j]['qtySell']>0),None)
         last=rows[end if end is not None else -1]
         seg.update(roundEndIndex=end,roundEndDate=last['date'],roundProfit=last['profit'],roundStatus='closed' if end is not None else 'censored',roundOutcome=sign(last['profit']) if end is not None else 'censored',roundHoldingCalendarDays=calendar(last['date'],r['date'])+1,roundAdds=sum(x['investAdded'] for x in rows[i:(end+1 if end is not None else len(rows))]),entryFeatures=r['features'],lFallbackProvenAbsent=r.get('lFallbackProvenAbsent',False))
         total['reentries']+=1;unitseg.append(seg);seg=None
        initial=False
      if r['qtySell']>0:
       total['sales']+=1;assert seg is None
       seg=dict(id=uid+'-'+str(r['date']),unit=uid,sample=sample,window=w,stock=st['ZSID'],name=st['ZSNAME'],sellDate=r['date'],sellIndex=r['index'],sellRow=i,sellPrice=r['price'],sellCategory=r['sellCategory'],flatIndices=[],entryIndex=None,entryDate=None,roundOutcome='noReentry',roundStatus='noReentry')
     if seg is not None:unitseg.append(seg);total['noReentrySegments']+=1;total['zeroObservationAfterSale']+=len(seg['flatIndices'])==0
     assert len(unitseg)==sum(r['qtySell']>0 for r in rows)
     allseg.extend(unitseg);progress('extract',unit=uid,segments=len(allseg),days=audit['independentRawDayChecks'])
 assert total['decisionDays']==109352 and total['sales']==len(allseg)
 assert total['sales']==total['reentries']+total['noReentrySegments']
 save('segments.json',allseg);save('source-hashes.json',HASH);save('extraction-complete.json',dict(counts=total,audit=audit,resources=usage(),strategyReplay=False))

def bg(h,r,s):
 return (r['price']>s['sellPrice'] and r['features']['d20']>0) if h['kind']=='H' else (r['price']<=s['sellPrice'] and r['features']['d20']<0)
def vol(n,f):
 return {'low':f['svz']<0,'low20':f['sv20']<0,'lowBoth':f['svz']<0 and f['sv20']<0,'high':f['svz']>1,'divergent':f['svz']>1 and f['mvz']<=0,'bothHigh':f['svz']>1 and f['mvz']>1,'highRising':f['svz']>1 and f['dsvz']>=0}[n]
def hit(h,r,s,variant):
 return not r['quality'] and (variant=='volumeOnly' or bg(h,r,s)) and (variant=='background' or vol(h['volume'],r['features']))
def hypotheses():
 return [dict(id=f'VRI-{fam}-{j}',family=fam,kind=kind,volume=v) for fam,kind,vs in [('M1','H',['low','low20','lowBoth']),('M2','H',['high','divergent','bothHigh']),('M3','L',['high','highRising','bothHigh'])] for j,v in enumerate(vs,1)]
def describe(xs):
 return dict(n=len(xs),stocks=len(set(x['stock'] for x in xs)),dates=len(set(x['entryDate'] for x in xs)),outcomes=dict(C.Counter(x['roundOutcome'] for x in xs)),medianEntryRelativeSellPct=med([x['entryRelativeSellPct'] for x in xs]),medianFlatDays=med([x['flatTradingDays'] for x in xs]),medianRoundDays=med([x['roundHoldingCalendarDays'] for x in xs]),bySample=dict(C.Counter(x['sample'] for x in xs)),byWindow=dict(C.Counter(x['window'] for x in xs)))
def summarize(paths):
 rel=[x for x in paths if x['releaseStatus']=='released'];ds=[x['releaseDeltaPct'] for x in rel]
 stocks=C.defaultdict(list);dates=C.defaultdict(list)
 for x in rel:stocks[x['stock']].append(x['releaseDeltaPct']);dates[x['entryDate']].append(x['releaseDeltaPct'])
 def drop(groups):
  if len(groups)<2:return None
  key=max(groups,key=lambda k:sum(-a for a in groups[k]));others=[v for k,vs in groups.items() if k!=key for v in vs]
  return dict(removed=key,remainingMeanDeltaPct=mean(others))
 return dict(n=len(paths),releaseStatus=dict(C.Counter(x['releaseStatus'] for x in paths)),lower=sum(x< -1e-8 for x in ds),higher=sum(x>1e-8 for x in ds),same=sum(abs(x)<=1e-8 for x in ds),meanDeltaPct=mean(ds),medianDeltaPct=med(ds),maxWait=max([x['releaseWait'] for x in rel],default=None),medianWait=med([x['releaseWait'] for x in rel]),byWindow={str(w):dict(n=len(a:=[x for x in rel if x['window']==w]),meanDeltaPct=mean([x['releaseDeltaPct'] for x in a])) for w in (1,2,3)},dropBestStock=drop(stocks),dropBestDate=drop(dates),fallbackAbsent=sum(x['lFallbackProvenAbsent'] for x in paths),largestMissedRisePct=max([x['maxRiseBeforeReleasePct'] for x in paths],default=None))
def evaluate():
 assert not (O/'evaluation-complete.json').exists();seg=read(O/'segments.json');hs=hypotheses();save('hypotheses-frozen.json',hs)
 units={};summaries=[];allfirst=[]
 for h in hs:
  kinds=[s for s in seg if s.get('entryRule')==h['kind'] and not s['quality']]
  background=[];full=[];excluded=[]
  for s in kinds:
   if s['unit'] not in units:units[s['unit']]=read(V/'units'/(s['unit']+'.json'))['rows']
   r=units[s['unit']][s['entryIndex']]
   if bg(h,r,s):
    background.append(s)
    (full if vol(h['volume'],r['features']) else excluded).append(s)
  results={}
  for variant in ('background','full','volumeOnly'):
   paths=[];first=[]
   for s in seg:
    if s['unit'] not in units:units[s['unit']]=read(V/'units'/(s['unit']+'.json'))['rows']
    rows=units[s['unit']];matches=[i for i in s['flatIndices'] if hit(h,rows[i],s,variant)]
    if matches:first.append(dict(hypothesis=h['id'],variant=variant,segment=s['id'],firstConditionDate=rows[matches[0]]['date'],conditionDays=len(matches),firstExecutableDate=s['entryDate'] if s.get('entryRule')==h['kind'] and s['entryIndex'] in matches else None))
    if not(s.get('entryRule')==h['kind'] and s['entryIndex'] in matches):continue
    i=s['entryIndex'];r=rows[i];end=s['roundEndIndex'] if s['roundEndIndex'] is not None else len(rows)-1
    release=next((j for j in range(i+1,end+1) if not hit(h,rows[j],s,variant)),None)
    status='released' if release is not None else 'originalRoundEndedStillBlocked' if s['roundEndIndex'] is not None else 'windowCensored'
    q=release if release is not None else end
    # Missing quality is contract fail-open, reported separately.
    if release is not None and rows[release]['quality']:status='missingDataFailOpen'
    future=rows[i+1:q+1]
    x={k:s[k] for k in ('id','unit','sample','window','stock','name','sellDate','sellPrice','entryDate','entryRule','entryPrice','entryRelativeSellPct','flatTradingDays','roundStatus','roundOutcome','roundProfit','roundHoldingCalendarDays','roundAdds','lFallbackProvenAbsent')}
    x.update(hypothesis=h['id'],variant=variant,releaseStatus=status,releaseDate=rows[q]['date'] if release is not None else None,releaseDeltaPct=100*(rows[q]['price']/r['price']-1) if release is not None else None,releaseWait=rows[q]['index']-r['index'] if release is not None else None,maxRiseBeforeReleasePct=max([100*(a['price']/r['price']-1) for a in future],default=0),maxFallBeforeReleasePct=min([100*(a['price']/r['price']-1) for a in future],default=0),executableAfterDivergence='unknown',features=r['features'])
    paths.append(x)
   save(f'paths/{h["id"]}-{variant}.json',paths);allfirst.extend(first);results[variant]=summarize(paths)
  # Descriptive price/time-adjusted negative-round rate difference. Quartiles
  # derive from background cohort only; no bin becomes a candidate condition.
  closed=[s for s in background if s['roundStatus']=='closed'];age=sorted(s['flatTradingDays'] for s in closed);price=sorted(s['entryRelativeSellPct'] for s in closed)
  cuts=lambda a:[a[int((len(a)-1)*p)] for p in (.25,.5,.75)] if a else []
  ac,pc=cuts(age),cuts(price);groups=C.defaultdict(lambda:[[],[]]);fullids={s['id'] for s in full}
  for s in closed:groups[(s['window'],bisect.bisect_left(ac,s['flatTradingDays']),bisect.bisect_left(pc,s['entryRelativeSellPct']))][int(s['id'] in fullids)].append(s)
  pairs=[]
  for k,(a,b) in groups.items():
   if a and b:pairs.append(dict(stratum=k,unblocked=len(a),blocked=len(b),negativeRateDifference=sum(x['roundProfit']<0 for x in b)/len(b)-sum(x['roundProfit']<0 for x in a)/len(a)))
  matched=sum(min(x['unblocked'],x['blocked']) for x in pairs)
  adj=sum(min(x['unblocked'],x['blocked'])*x['negativeRateDifference'] for x in pairs)/matched if matched else None
  summary=dict(hypothesis=h,allType=describe(kinds),background=describe(background),full=describe(full),unblockedBackground=describe(excluded),priceTimeAdjusted=dict(matchedWeight=matched,negativeRateDifference=adj,ageQuartiles=ac,priceQuartiles=pc,strata=pairs),variants=results)
  summaries.append(summary);progress('evaluate',hypothesis=h['id'],fullEvents=len(full))
 save('first-condition-and-executable.json',allfirst);save('screening.json',summaries);save('source-hashes-analysis.json',HASH);save('evaluation-complete.json',dict(hypotheses=len(hs),masks=len(hs)*3,firstConditionRecords=len(allfirst),resources=usage(),strategyReplay=False))

if __name__=='__main__':
 try:
  if sys.argv[1]=='extract':extract()
  elif sys.argv[1]=='evaluate':evaluate()
 except Exception as e:
  save('failure-'+str(int(time.time()))+'.json',dict(stage=sys.argv[1:],error=repr(e),resources=usage()));raise
