#!/usr/bin/env python3
"""LC-P01: read-only source extraction, frozen dictionary and <=1000 calibration pairs.
No strategy replay, candidate ranking, market download or source database writes.
"""
import os
for k in ('OMP_NUM_THREADS','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS','VECLIB_MAXIMUM_THREADS','NUMEXPR_NUM_THREADS'):os.environ[k]='1'
import argparse,bisect,collections as C,copy,hashlib,itertools,json,math,resource,shutil,sqlite3,subprocess,time
from pathlib import Path
import numpy as np
import h_entry_composite as h
import h_entry_composite_p02 as prior
import h_entry_composite_search as gen
import l_entry_delay_features as fx
R=Path(__file__).resolve().parents[1];O=R/'exports/loss-exit-p01-20261002'
RULE='7ba8447fbf207484ab305cad0c6beca216da8c93';STRATEGY='s49-sell-delay-f03-r1-20261001';NAN=float('nan')
START=time.monotonic();CPU=time.process_time();HASH={}
resource.setrlimit(resource.RLIMIT_CPU,(1800,1800))
def sha(p):
 z=hashlib.sha256()
 with Path(p).open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):z.update(b)
 return z.hexdigest()
def source(p):
 p=Path(p);HASH[str(p.relative_to(R))]=sha(p);return p
def read(p):return json.loads(source(p).read_text())
def save(name,obj):
 p=O/name;p.parent.mkdir(parents=True,exist_ok=True);tmp=p.with_suffix(p.suffix+'.tmp');tmp.write_text(json.dumps(obj,ensure_ascii=False,allow_nan=False,separators=(',',':'))+'\n');tmp.replace(p)
def usage():return dict(elapsedSeconds=round(time.monotonic()-START,3),cpuSeconds=round(time.process_time()-CPU,3),peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,allocatedBytes=sum(p.stat().st_blocks*512 for p in O.rglob('*') if p.is_file()))
def guard():
 u=usage();assert u['peakRSSBytes']<=512*1024**2,u;assert u['allocatedBytes']<=256*1024**2,u;assert u['cpuSeconds']<1800,u;assert u['elapsedSeconds']<600,u
 return u
def progress(stage,**kw):
 u=guard();save('status.json',dict(stage=stage,**kw,resources=u));print(json.dumps(dict(stage=stage,**kw,resources=u)),flush=True)
def db(p):
 source(p)
 for suffix in ('-wal','-shm'):
  q=Path(str(p)+suffix)
  if q.exists():
   source(q)
   if suffix=='-wal':assert q.stat().st_size==0,q
 c=sqlite3.connect(p.as_uri()+'?mode=ro&immutable=1',uri=True);c.row_factory=sqlite3.Row;assert c.execute('pragma quick_check').fetchone()[0]=='ok';return c
def eq(a,b):assert math.isclose(a,b,rel_tol=1e-10,abs_tol=1e-6),(a,b)
def clean(x):return float(x) if x is not None and math.isfinite(x) else None
def rnd(x):return math.floor(x+.5)
def fees(price,qty):return max(20,rnd(price*qty*1000*.001425))+rnd(price*qty*1000*.003)
def preflight():
 protocol=read(O/'protocol.json');assert protocol['maxCalibrationStructures']==1000
 assert subprocess.check_output(['git','rev-parse',RULE+'^{commit}'],cwd=R,text=True).strip()==RULE
 for f in ('technical.swift','RollingContext.swift','dataModel.swift','InternalBacktestDecisionBase.swift','SellDelayF01Rule.swift','SellDelayF03Rule.swift'):
  p=source(R/'simStock3'/f);assert p.read_bytes()==subprocess.check_output(['git','show',RULE+':simStock3/'+f],cwd=R)
 for p in [h.MARKET/'market-daily.csv',h.MARKET/'market-technical.csv',h.PATHS]:source(p)
 for f in ('loss_exit_p01.py','l_entry_delay_features.py','h_entry_composite.py','h_entry_composite_p02.py','h_entry_composite_search.py','fwd_v20_path_discovery.py','market_technical.py'):
  p=source(R/'tools'/f);d=O/'tool-sources'/f;d.parent.mkdir(exist_ok=True);shutil.copyfile(p,d)
 return protocol

def gates(e,fit,r,prev,n,gap,ms,day):
 grade=e['grade'];roi=e['unit_roi_before'];days=e['holding_days_before'];score=e['decision_score'];no60=gap is None or gap>=60
 a=score>=(1 if grade>=0 and days<400 else 2)
 b=days>240 and r['ZTLOWDIFF125']-r['ZTHIGHDIFF125']<30 and ((roi>-15 and grade>-1) or (roi>-20 and (days>300 or grade<=-1)))
 c=days>400 and roi>(-20 if grade<=-1 else -15)
 cutE=grade!=0 and days>90 and roi>(-20 if grade in (-1,1) else -17.5) and a
 g=grade>=2 and days>120 and roi<=-17.5 and a
 hh=days>120 and -25<roi<0 and fit['fit_level'] < -10 and a and no60
 normal=(a and (b or c) or cutE) and no60;cut=normal or g or hh
 # Profit gates are reconstructed from the official preview (not today's persisted phase).
 roiAnnual=e['roll_roi_before']/prior.years(day,gates.start)
 av=prior.avdays(e['roll_rounds_before'],e['roll_days_before'],e['inventory_before'],days)
 phase,_,count,*_=prior.fit_update(prior.ownstate(prev),prior.level_of(roiAnnual,av),roiAnnual,av)
 lower=(1.5 if grade<=-1 else 2.25 if grade==3 else 2.)
 if grade!=0 and days>1 and r['ZTPRICEPATHPHASERAW'] in (4,5) and count>=125 and phase==9:lower=.45
 pb={'S-T01a':roi>22.5 and score>(0 if grade>=2 else 1),'S-T01b':score>=6 and roi>.45 and days>1,
 'S-T01c':score>=4 and roi>lower,'S-T01d':score>=4 and roi>3.5 and (r['ZTKDKZ125']>1.5 or r['ZTKDDZ125']>1.5),
 'S-T01e':score>=4 and roi>.45 and days>1 and days>68,'S-T01f':score>=3 and roi>15.5 and days<(60 if grade>=2 else 40),
 'S-T01g':score>=3 and roi>9.5 and days<(30 if grade>=2 else 20),'S-T01h':score>=3 and roi>6.5 and days<(45 if grade<=-1 else 10)}
 base=any(pb.values());m=ms[0].get(day);pm=ms[0].get(h.dateof(prev['ZDATETIME']));mp=ms[2].get(day)
 def val(row,k):return float(row[k]) if row and row.get(k) not in ('',None) else NAN
 mature=n>=249 and val(m,'price_observation_count')>=250
 z=val(m,'market_high_diff_z_250');od=r['ZTOSCZ125']-prev['ZTOSCZ125'];md=val(m,'market_osc_z_125')-val(pm,'market_osc_z_125')
 e1tech=mature and val(pm,'price_observation_count')>=125 and all(math.isfinite(x) for x in (z,r['ZTOSCMAX9'],od,md)) and -.97<z<.83 and r['ZTOSCMAX9']<0 and (od<.22 or md>0) and (grade>=1 or (math.isfinite(r['ZTLOWDIFF']) and r['ZTLOWDIFF']>-.53))
 e1=not base and cut and e1tech
 m20=val(m,'market_ma_20_diff_max_9');lz=val(m,'market_low_diff_z_125')
 e2tech=mature and all(math.isfinite(x) for x in (m20,lz,r['ZPRICEHIGH'],r['ZTHIGHMAX9'])) and m20<1.2 and mp and int(mp['phase_raw']) in (2,3) and (r['ZPRICEHIGH']!=r['ZTHIGHMAX9'] or lz<0)
 e2=bool((base or cut) and not e1 and e2tech);normalSell=(base or cut) and not e1 and not e2
 net=r['ZPRICECLOSE']*e['inventory_before']*1000-prev['ZSIMAMTCOST']-fees(r['ZPRICECLOSE'],e['inventory_before'])
 expected=[k for k,v in pb.items() if v]+(['S-T02'] if a and (b or c) else [])+(['S-T02e'] if cutE else [])+(['S-T02g'] if g else [])+(['S-T02h'] if hh else [])+(['S-E01'] if e1 else [])+(['S-E02'] if e2 else [])
 return dict(scoreGate=a,no60=no60,base=base,cut=bool(cut),b=b,c=c,e=cutE,g=g,h=hh,E01=bool(e1),E02=e2,normalSell=bool(normalSell),net=net,expected=expected,
 earlyEligible=bool(net<0 and a and no60 and not base and not e1tech and not e2tech),lateEligible=bool(normalSell and net<0 and not base))

def extract():
 protocol=preflight();cat=read(R/'exports/add-delay-p02-20261002/feature-catalog.json');assert len(cat)==292
 for c in cat:
  c.update(status='LC-P01-causal-baseline-features',searched=False,anchorRole='predecision before any candidate divergence',futureRole='candidate own S unknown after divergence' if c['group']=='S' else 'causal fixed input',timing='current/prior only, never same-day settlement or future labels')
 fx.CAT=cat;fx.NEW=read(R/'exports/h-entry-composite-p01-20260929/proposed-features.json');names=[c['name'] for c in cat]
 save('feature-catalog.json',cat);ms=prior.market_inputs();marketdays=sorted(ms[1]);mset=set(marketdays);ident={};units=[];checks=C.Counter()
 for sample in 'CD':
  bp=next(R.glob('exports/backtest-decision-bases/'+sample.lower()+'-*-s49-*-v23'));rp=next(R.glob('exports/backtest-reports/baseline-'+sample.lower()+'-v37-*-fixed3y-*'))
  for d in (bp,rp):
   m=read(d/'manifest.json');assert m['ruleCommit']==RULE and m['dataRuleVersion']=='T3/S61' and m['ruleVersion']==STRATEGY and m['moneyBaseWan']==600 and m['automaticInvestments']==2 and m['through']=='2026/07/22';source(d/'.complete')
  ident[sample]=dict(report=str(rp.relative_to(R)),decisionBase=str(bp.relative_to(R)))
  with db(bp/'decisions.sqlite') as c:
   meta=dict(c.execute('select * from metadata'));assert meta['ruleCommit']==RULE and meta['dataRuleVersion']=='T3/S61' and meta['formatVersion']=='6'
   ev={(x['window_id'],x['stock_id'],x['trade_date']):dict(x) for x in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=1')}
   se={(x['window_id'],x['stock_id'],x['trade_date']):dict(x) for x in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=3')}
   fits={(x['window_id'],x['stock_id'],x['trade_date']):dict(x) for x in c.execute('select o.*,s.stock_id from strategy_fit_observations o join stocks s using(stock_key)')}
   gs=C.defaultdict(set)
   for x in c.execute('select event_id,rule_id from event_gates join rules using(rule_key)'):gs[x[0]].add(x[1])
   scores={x[0]:x[1] for x in c.execute('select event_id,sum(contribution) from event_votes group by event_id')}
  for w,(fn,start,end) in h.WINDOWS.items():
   gates.start=start
   with db(rp/fn) as c:
    stocks=[dict(x) for x in c.execute('select * from ZSTOCK')];assert len(stocks)==10
    for stock in stocks:
     sid=stock['ZSID'];unit=f'{sample}-{w}-{sid}';done=O/'units'/f'{unit}.json';arr=O/'units'/f'{unit}.npz'
     assert stock['ZTECHNICALSTATEVERSION']==3 and stock['ZSIMULATIONSTATEVERSION']==61 and stock['ZTECHNICALDIRTYFROM'] is None and stock['ZSIMULATIONDIRTYFROM'] is None
     unitIdentity=dict(rule=RULE,store=HASH[str((rp/fn).relative_to(R))],extractor=HASH['tools/loss_exit_p01.py'],dictionary=sha(O/'feature-catalog.json'),market=HASH[str((h.MARKET/'market-technical.csv').relative_to(R))])
     if done.exists():
      old=json.loads(done.read_text());assert old['identity']==unitIdentity and sha(arr)==old['arraySHA256'];units.append(unit);checks.update(old['checks']);progress('resume-unit',unit=unit);continue
     raw=[dict(x) for x in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(stock['Z_PK'],))];dates=[h.dateof(x['ZDATETIME']) for x in raw];assert dates==sorted(set(dates))
     context=prior.ctx();rows=[];matrix=[];uc=C.Counter();roundid=0;allMissing=sorted(d for d in marketdays if max(start,dates[0])<=d<=end and d not in set(dates))
     for n,r in enumerate(raw):
      day=dates[n]
      if day>end:break
      key=(w,sid,day);e=ev.get(key);fit=fits.get(key);prev=raw[n-1] if n else None;gap=context['invest_distance'];before=copy.deepcopy(context) if e and n%113==0 else None
      f=fx.values(raw,n,stock,start,e,fit,ms,context,uc)
      holding=bool(e and e['inventory_before']>0 and n)
      for name in ('inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before'):f[name]=e[name] if holding else NAN
      f['buy_rule_before']={'H':1.,'L':2.}.get(e['buy_rule_before'],NAN) if holding else NAN
      f['holding_cost_before']=prev['ZSIMAMTCOST'] if holding else NAN;f['tradingDaysSinceLastInvestment']=gap if holding and gap is not None else NAN
      if not start<=day<=end:continue
      assert r['ZDATASOURCE']=='TWSE' and not r['ZSIMREVERSED'] and not r['ZSIMINVESTBYUSER']
      if r['ZSIMQTYBUY']>0 and (not prev or prev['ZSIMQTYINVENTORY']==0):roundid+=1
      quality=[]
      if day not in mset or day not in ms[0] or day not in ms[2]:quality.append('missingMarket')
      if r['ZVOLUMECLOSE']<=0:quality.append('zeroVolumeUnconfirmedTradability')
      if not all(math.isfinite(r[k]) and r[k]>0 for k in ('ZPRICEOPEN','ZPRICEHIGH','ZPRICELOW','ZPRICECLOSE')) or not r['ZPRICELOW']<=min(r['ZPRICEOPEN'],r['ZPRICECLOSE'])<=max(r['ZPRICEOPEN'],r['ZPRICECLOSE'])<=r['ZPRICEHIGH']:quality.append('invalidOHLC')
      rec=dict(date=day,round=roundid,held=holding,price=r['ZPRICECLOSE'],volume=r['ZVOLUMECLOSE'],qtyBefore=e['inventory_before'] if e else 0,costBefore=prev['ZSIMAMTCOST'] if holding else None,qtySell=r['ZSIMQTYSELL'],profit=r['ZSIMAMTPROFIT'],qtyBuy=r['ZSIMQTYBUY'],postQty=r['ZSIMQTYINVENTORY'],quality=quality,gap=gap)
      if holding:
       sell=se[key];assert fit is not None
       for k in ('grade','inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before','balance_before','roll_roi_before','roll_days_before','roll_rounds_before','buy_rule_before'):assert e[k]==sell[k];uc['HvsSellPrestate']+=1
       eq(sell['inventory_before'],prev['ZSIMQTYINVENTORY']);eq(sell['unit_cost_before'],prev['ZSIMUNITCOST']);eq(sell['balance_before'],prev['ZSIMAMTBALANCE']);eq(sell['unit_roi_before'],100*(r['ZPRICECLOSE']/prev['ZSIMUNITCOST']-1));eq(sell['holding_days_before'],prev['ZSIMDAYS']+rnd((r['ZDATETIME']-prev['ZDATETIME'])/86400));eq(scores.get(sell['event_id'],0),sell['decision_score']);uc['prestateAndVoteChecks']+=6
       g=gates(sell,fit,r,prev,n,gap,ms,day);assert set(g['expected'])==gs[sell['event_id']],(unit,day,g['expected'],gs[sell['event_id']]);assert g['normalSell']==(sell['planned_action']=='SELL')==(r['ZSIMQTYSELL']>0),(unit,day,g)
       uc['fullSellGatesAndPriority']+=1
       if r['ZSIMQTYSELL']>0:
        eq(r['ZSIMQTYSELL'],prev['ZSIMQTYINVENTORY']);assert r['ZSIMQTYINVENTORY']==0;eq(g['net'],r['ZSIMAMTPROFIT']);eq(r['ZSIMAMTBALANCE'],prev['ZSIMAMTBALANCE']+r['ZPRICECLOSE']*r['ZSIMQTYSELL']*1000-fees(r['ZPRICECLOSE'],r['ZSIMQTYSELL']));uc['saleAccounting']+=1
       rec.update(event=sell['event_id'],grade=sell['grade'],unitROI=sell['unit_roi_before'],holdingDays=sell['holding_days_before'],buyRule=sell['buy_rule_before'],gates=g)
      else:assert key not in se and r['ZSIMQTYSELL']==0
      if before is not None:
       changed=dict(r)
       for k in changed:
        if k.startswith(('ZSIM','ZROLL')) and isinstance(changed[k],(int,float)):changed[k]=123456789.
       alt=fx.values(raw[:n]+[changed,{'ZPRICECLOSE':-999}],n,stock,start,e,fit,ms,before,C.Counter(),verify_post=False)
       for name in names:
        if name in ('inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before','buy_rule_before','holding_cost_before','tradingDaysSinceLastInvestment'):continue
        assert f.get(name,NAN)==alt.get(name,NAN) or (not prior.finite(f.get(name,NAN)) and not prior.finite(alt.get(name,NAN))),(unit,day,name,'future/post leak')
       uc['poststateFuturePoisonControls']+=1
      assert set(names)<=set(f),(unit,set(names)-set(f))
      matrix.append([f[name] if prior.finite(f[name]) else NAN for name in names]);rows.append(rec)
      if n%200==0:guard()
     X=np.asarray(matrix,dtype=np.float64);arr.parent.mkdir(exist_ok=True);tmp=arr.with_suffix('.tmp.npz');np.savez_compressed(tmp,X=X);tmp.replace(arr)
     save('units/'+unit+'.json',dict(identity=unitIdentity,arraySHA256=sha(arr),sample=sample,window=w,stock=sid,start=start,end=end,rows=rows,missingMarketSessions=allMissing,checks=dict(uc)))
     checks.update(uc);units.append(unit);save('checkpoint.json',dict(completedUnits=units,lastUnit=unit,sourceHashes=HASH));progress('extract',unit=unit,units=len(units),rows=len(rows))
 save('identities.json',ident);save('source-hashes.json',HASH);save('extraction.json',dict(units=units,checks=dict(checks),resources=guard()))

def load_units():
 data=json.loads((O/'extraction.json').read_text());cat=json.loads((O/'feature-catalog.json').read_text());allx=[];meta=[];units=[]
 for uid in data['units']:
  d=json.loads((O/'units'/f'{uid}.json').read_text());p=O/'units'/f'{uid}.npz';assert sha(p)==d['arraySHA256'];x=np.load(p)['X'];allx.append(x);units.append(d)
  meta.extend((d['sample'],d['window'],d['stock'],r) for r in d['rows'])
 return cat,np.concatenate(allx),meta,units

def make_atoms(X,cat):
 out=[]
 for j,c in enumerate(cat):
  column=X[:,j];ok=np.isfinite(column);v=column[ok]
  if not len(v):continue
  defs=[]
  if c['kind']=='boolean':defs=[('eq',0.),('eq',1.)]
  elif c['kind']=='category':defs=[(op,float(x)) for x in c['values'] for op in ('eq','ne')]
  elif c['kind']=='grade':defs=[(op,x) for x in (-2.5,-1.5,.5,1.5,2.5) for op in ('lt','gt')]
  else:
   cuts={gen.coarse(float(np.quantile(v,q))) for q in (.25,.5,.75)}
   if min(v)<0<max(v):cuts.add(0.)
   defs=[(op,x) for x in sorted(cuts) for op in ('lt','gt')]
   lo,hi=(gen.coarse(float(np.quantile(v,q))) for q in (.25,.75))
   if lo<hi:defs.append(('between',(lo,hi)))
  seen=set();valid=gen.bits(ok)
  for op,val in defs:
   m=ok & ({'lt':lambda:column<val,'gt':lambda:column>val,'eq':lambda:column==val,'ne':lambda:column!=val,'between':lambda:(column>val[0])&(column<val[1])}[op]())
   mask=gen.bits(m)
   if mask==0 or mask==valid:continue
   seen.add(mask);out.append(gen.Atom(len(out),c['name'],c['parent'],c['group'],op,val,mask,valid))
 return out

def freeze():
 assert not (O/'labels.json').exists(),'Freeze must precede future-price labels'
 cat,X,meta,_=load_units();sel=np.array([w in (1,2) and r['held'] for s,w,stock,r in meta]);atoms=make_atoms(X[sel],cat)
 # Keep distinct formulas even when discovery masks coincide.
 out=[dict(id=a.id,name=a.name,parent=a.parent,group=a.group,op=a.op,value=a.value) for a in atoms]
 counts=C.Counter(a.group for a in atoms);parents=C.defaultdict(C.Counter)
 for a in atoms:parents[a.group][a.parent]+=1
 pairs={g+k:counts[g]*counts[k] if g!=k else (counts[g]**2-sum(v*v for v in parents[g].values()))//2 for g,k in [('T','T'),('S','S'),('M','M'),('T','S'),('T','M'),('S','M')]}
 save('atoms.json',out);save('search-budget.json',dict(atoms=len(atoms),fieldsWithAtoms=len({a.name for a in atoms}),atomGroups=dict(counts),structuresByGroup=pairs,structures=sum(pairs.values()),directionEvaluations=2*sum(pairs.values()),batches100k=math.ceil(sum(pairs.values())/100000),overProposed2100=len(atoms)>2100,thresholdRows=int(sel.sum()),thresholdSource='C/D W1-W2 all held predecision inputs, before LC future-price labels',generation='existing coarse quartiles (2 significant digits) plus 0, declared category/grade boundaries; distinct formulas retained even when observational masks coincide, no effect selection',scope='fixed dictionary only; not all possible thresholds; no TSM possible with two values'))
 save('availability.json',[dict(name=c['name'],group=c['group'],finiteAll=int(np.isfinite(X[:,j]).sum()),finiteHeldDiscovery=int(np.isfinite(X[sel,j]).sum()),atoms=sum(a.name==c['name'] for a in atoms),latePostS='unknown' if c['group']=='S' else 'fixed causal') for j,c in enumerate(cat)])
 # Stratified round-robin deterministic structural selection; no outcome scoring.
 iters={}
 def pairs_for(group):
  return ((a.id,b.id) for a in atoms for b in atoms if a.id<b.id and a.parent!=b.parent and gen.group_key({a.group,b.group})==gen.group_key(set(group)))
 for group in pairs:iters[group]=pairs_for(group)
 chosen=[];active=list(iters)
 while len(chosen)<1000 and active:
  for group in list(active):
   try:pair=next(iters[group]);chosen.append(dict(id=len(chosen),group=group,atoms=list(pair)))
   except StopIteration:active.remove(group)
   if len(chosen)==1000:break
 assert len({tuple(x['atoms']) for x in chosen})==len(chosen)
 save('calibration-spec.json',dict(structures=chosen,atomsSHA256=sha(O/'atoms.json'),rows=int(len(X)),selection='deterministic round robin six source strata; no labels',noPerformanceRanking=True));progress('freeze',atoms=len(atoms),structures=sum(pairs.values()),calibration=len(chosen))

def labels():
 spec=json.loads((O/'calibration-spec.json').read_text());assert spec['atomsSHA256']==sha(O/'atoms.json')
 cat,X,meta,units=load_units();scols=[j for j,c in enumerate(cat) if c['group']=='S'];events=[];tot=C.Counter();coverage=[];offset=0;lateX=[];lateKeys=[]
 for d in units:
  rows=d['rows'];counts=C.Counter();missing=d['missingMarketSessions'];name=f"{d['sample']}-{d['window']}-{d['stock']}"
  for i,r in enumerate(rows):
   counts['rows']+=1;counts['heldDays']+=r['held'];counts['sells']+=r['qtySell']>0
   if not r['held']:continue
   g=r['gates'];counts['cutQualifiedDays']+=g['cut'];counts['earlyEligibleDays']+=g['earlyEligible'];counts['earlyAdditionalDays']+=g['earlyEligible'] and not g['normalSell'];counts['deferredE01Days']+=g['E01'];counts['deferredE02Days']+=g['E02']
   if not r['qtySell']:continue
   route='both' if g['base'] and g['cut'] else 'profit' if g['base'] else 'recovery'
   counts['sellRoute_'+route]+=1
   if r['profit']>=0:continue
   counts['loss']+=1;counts['feeOnlyLoss']+=r['unitROI']>=0;counts['lossRoute_'+route]+=1
   event=dict(sample=d['sample'],window=d['window'],stock=d['stock'],date=r['date'],index=offset+i,round=r['round'],price=r['price'],profit=r['profit'],unitROI=r['unitROI'],feeOnly=r['unitROI']>=0,route=route,gates=g['expected'],ownSAfterDivergence='unknown',sides={})
   for side,indices in [('early',list(range(max(0,i-10),i))),('late',list(range(i+1,min(len(rows),i+11))))]:
    points=[rows[j] for j in indices];bad=[]
    if len(points)!=10:bad.append('windowCensored')
    if any(p['quality'] for p in points+[r]):bad.append('rowQuality')
    lo=min([r['date']]+[p['date'] for p in points]);hi=max([r['date']]+[p['date'] for p in points]);gaps=[x for x in missing if lo<=x<=hi]
    if gaps:bad.append('unresolvedMissingStockSessions')
    if side=='early' and any(not p['held'] or p['round']!=r['round'] for p in points):bad.append('notSameHoldingRound')
    px=[p['price'] for p in points];mx=max(px) if px else None;more=[p for p in points if p['price']>r['price']]
    sideData=dict(indices=[offset+j for j in indices],dates=[p['date'] for p in points],prices=px,count=len(points),issues=bad,missingDates=gaps,qualityEligible=not bad,maxClose=mx,maxDates=[p['date'] for p in points if p['price']==mx],firstHigherDate=more[0]['date'] if more else None,observedHigher=bool(more),label='opportunity upper bound only, not attainable profit or score',SAfterAction='unknown')
    if side=='early':
     eligible=[p for p in points if p['held'] and p['gates']['earlyEligible'] and not p['gates']['normalSell'] and not p['quality']]
     sideData.update(eligibleAdditionalDates=[p['date'] for p in eligible],higherEligibleDates=[p['date'] for p in eligible if p['price']>r['price']],localNetAtEachDate=[p['gates']['net'] if p['held'] else None for p in points],sameQuantityAll=all(p['qtyBefore']==r['qtyBefore'] for p in points),capitalWarning='local nets use each date inventory/cost; not additive causal savings')
    else:
     sideData['frozenPositionNetUpperBound']=max((p['price']*r['qtyBefore']*1000-r['costBefore']-fees(p['price'],r['qtyBefore']) for p in points),default=None);sideData['baselineLaterSUsed']=False
    event['sides'][side]=sideData;counts[side+'Complete']+=len(points)==10;counts[side+'QualityEligible']+=not bad;counts[side+'HigherEligible']+=not bad and bool(more)
    for issue in bad:counts[side+'_'+issue]+=1
   for j in range(i,min(len(rows),i+11)):
    values=X[offset+j].copy()
    if j>i:values[scols]=NAN
    lateKeys.append(dict(event=len(events),offset=j-i,index=offset+j));lateX.append(values)
   events.append(event)
  coverage.append(dict(unit=name,counts=dict(counts),missingStockSessions=missing));tot.update(counts);offset+=len(rows)
 lateX=np.asarray(lateX);assert np.isnan(lateX[np.array([r['offset']>0 for r in lateKeys])][:,scols]).all()
 np.savez_compressed(O/'late-masked.npz',X=lateX);save('late-keys.json',lateKeys);save('labels.json',events);save('coverage.json',dict(cells=coverage,totals=dict(tot),events=len(events),unknownFutureSFields=len(scols),lateRows=len(lateKeys),dictionarySHA256=sha(O/'atoms.json')));progress('labels',events=len(events),totals=dict(tot))

def mask(a,X,names):
 x=X[:,names.index(a['name'])];ok=np.isfinite(x);v=a['value'];op=a['op'];m={'lt':lambda:x<v,'gt':lambda:x>v,'eq':lambda:x==v,'ne':lambda:x!=v,'between':lambda:(x>v[0])&(x<v[1])}[op]()&ok
 return gen.bits(m),gen.bits(ok)
def calibrate():
 cat,X,meta,units=load_units();names=[c['name'] for c in cat];atoms=json.loads((O/'atoms.json').read_text());spec=json.loads((O/'calibration-spec.json').read_text());assert spec['atomsSHA256']==sha(O/'atoms.json');coverage=json.loads((O/'coverage.json').read_text())
 early=gen.bits(np.array([r['held'] and r['gates']['earlyEligible'] and not r['gates']['normalSell'] and not r['quality'] for s,w,stock,r in meta]));late=gen.bits(np.array([r['held'] and r['gates']['lateEligible'] and not r['quality'] for s,w,stock,r in meta]));used={i for c in spec['structures'] for i in c['atoms']};masks={i:mask(atoms[i],X,names) for i in used};del X
 cp=O/'calibration-checkpoint.json';res=[]
 identity=dict(atoms=sha(O/'atoms.json'),spec=sha(O/'calibration-spec.json'),coverage=sha(O/'coverage.json'),extractor=sha(Path(__file__)))
 if cp.exists():
  old=json.loads(cp.read_text());assert old['identity']==identity;res=old['results'];assert [x['id'] for x in res]==list(range(len(res)))
 start=time.perf_counter();base=len(res)
 for block in range(base,len(spec['structures']),100):
  for specrow in spec['structures'][block:block+100]:
   a,b=specrow['atoms'];hit=masks[a][0]&masks[b][0];valid=masks[a][1]&masks[b][1]
   res.append(dict(id=specrow['id'],earlyHits=(hit&early).bit_count(),earlyUnknown=(early&~valid).bit_count(),lateHits=(hit&late).bit_count(),lateUnknown=(late&~valid).bit_count()))
  save('calibration-checkpoint.json',dict(identity=identity,results=res,nextID=len(res)));progress('calibrate',structures=len(res))
 elapsed=time.perf_counter()-start;assert len(res)==len(spec['structures'])<=1000
 # Simulate checkpoint split/resume locally over the SAME 1000 IDs; no additional formula structures.
 recomputed=[]
 for c in spec['structures']:
  a,b=c['atoms'];hit=masks[a][0]&masks[b][0];valid=masks[a][1]&masks[b][1];recomputed.append(dict(id=c['id'],earlyHits=(hit&early).bit_count(),earlyUnknown=(early&~valid).bit_count(),lateHits=(hit&late).bit_count(),lateUnknown=(late&~valid).bit_count()))
 assert recomputed==res;assert len({tuple(c['atoms']) for c in spec['structures']})==1000
 save('calibration.json',dict(structures=1000,directionEvaluations=2000,verificationRepeatStructures=1000,newStructuresOutsideSpec=0,elapsedSeconds=elapsed,structuresPerSecond=(len(res)-base)/elapsed if elapsed else None,includesCheckpointIO=True,earlyEligibleAllDays=early.bit_count(),lateEligible=late.bit_count(),sourceGroups=dict(C.Counter(c['group'] for c in spec['structures'])),resumeEquivalent=True,results=res,candidateCards=0,noOutcomeRanking=True,limits='Only Boolean/eligibility throughput measured; full path/label ranking costs unmeasured',resources=guard()))
 progress('calibration-complete',structures=1000)

def main():
 stage=argparse.ArgumentParser();stage.add_argument('stage',choices=['extract','freeze','labels','calibrate']);args=stage.parse_args()
 try:globals()[args.stage]()
 except Exception as e:
  save('failure-'+args.stage+'.json',dict(error=repr(e),resources=usage()));raise
if __name__=='__main__':main()
