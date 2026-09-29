#!/usr/bin/env python3
"""HC-Q10: independent ten-session flat branches and precision-first discovery.
Never mutates stores or extrapolates through a hypothetical purchase.
"""
from pathlib import Path
from collections import Counter,defaultdict
import json,math,sys,hashlib,time,itertools
import numpy as np
import h_entry_composite as h
import h_entry_composite_p02 as p
import h_entry_composite_p03 as p3
import h_entry_composite_search as eng
R=h.ROOT;O=R/'exports/h-entry-composite-precision-20260929';P=p.O
read=lambda f:json.loads(f.read_text())
def save(n,v):
 q=O/(n+'.tmp');q.write_text(json.dumps(v,ensure_ascii=False,indent=2,allow_nan=False)+'\n');q.replace(O/n)
def grade(roi,days,rounds,penalty,phase):
 if rounds<=2 and days<=360:return 0
 z=p.level_of(roi,days)
 g=3 if z>46 else 2 if z>39 else 1 if z>23 else -1 if z>=-5 else -2 if z>=-23 else -3
 return {3:2,2:1,1:-1,-1:-2,-2:-2,-3:-3}[g] if penalty and phase==10 else g

def votes(r,prev,g,phase,count,ext,prior,penalty,boundary,market):
 """Release S45 H/L score transcription; audited against DecisionBase and existing candidate paths."""
 v=lambda name:r['Z'+name.upper()]
 by=lambda low,mid,high=None:low if g<=-1 else high if high is not None and g>=2 else mid
 pp=int(v('tpricepathphaseraw'));mm=h.dateof(r['ZDATETIME'])%10000
 mphase=int(market['phase_raw']) if market else 0
 a=v('tma60diffz125')>(.85 if g<=-1 else .75) and v('tma60diffz125')<(2 if g<=-2 else 2.5)
 b=v('tma20diff')-v('tma60diff')>1 and v('tma20days')>0 and not(g!=0 and pp==1 and not a)
 c=(v('tma60diff')>by(-.5,0) and v('tma20diff')>by(-.5,0) and not(mphase==3 and g!=0 and count>=125 and phase==9 and pp in (4,5))) or g==-3
 high9=bool(market and market.get('is_high9'))
 d=prev['ZVZ125']>(2 if g<=-1 else 1.5) and not(g>=1 and phase!=1 and mphase!=2 and high9)
 warmbad=count>=125 and phase in (3,10,11)
 H=int(a)+int(b)+int(c)+int(d)-int(v('volumeclose')==v('vmin9'))
 H-=int((v('toscz125')>1.8 and v('tkdjz125')>1.5 and (g<2 or (g>=2 and warmbad))) or v('tkdjz125')>1.8)
 H-=int(v('tkdkz125')<-.8 or v('tkdkz125')>(2 if g<=-1 else 1.8))
 H-=int(v('toscz125')<-.5)
 minflags=[v(n)==v(n+'min9') for n in ('tma60diff','tma20diff','tkdk','tosc')]
 H-=int(any(minflags) and g>=-2)
 ma20=v('tma20diffmax9')-v('tma20diffmin9');ma60=v('tma60diffmax9')-v('tma60diffmin9')
 H-=int(g<=-1 and (ma20>6 or ma60>7));H-=int(g==-3 and (ma20>6 or ma60>7));H-=int(g==-3 and v('tma20diffz125')>1.6)
 H-=int(v('thighdiffz125')>by(.4,1.1,1.3) and v('tlowdiffz125')>by(.5,1.2,1.5))
 H-=int((726 if g<=-1 else 801)<=mm<=810);H-=int((221 if g<=-1 else 226)<=mm<=305)
 H+=int(801<=mm<=831)+int(301<=mm<=331)
 H-=int(warmbad and g<=0);H-=int(penalty>0 and g==-3)
 H-=int(g==3 and pp==2 and v('tkdkz125')>1.8 and v('tkdjz125')>1.8)
 L=int(v('tkdj')<-1 or v('tkdk')<9)+int(v('tkdj')<-7)
 suppress=pp==1 and (g<=-2 or (count>=125 and phase==10 and ext is not None and ext<=-.911888))
 L+=int(v('tkdkz125')<-.9 and v('tkdkz250')<-.9 and not suppress)
 L+=int(v('tkddz125')<-.9 and v('tkddz250')<-.9)+int(v('toscz125')<-.9 and v('toscz250')<-.9)
 L+=int(v('vz125')<by(-.2,.3))+int(sum(minflags)>=2 and v('tma60diffz125')>-.5 and g>=0)
 L+=int(v('thighdiffz125')<by(-1.5,-1.35,-1.2));L-=int(v('tma20days')<-20)
 prioractive=prior[2]>=125 and prior[5] is not None and abs(prior[5])>.611888
 L-=int(minflags[0] and minflags[1] and minflags[3] and (g==-3 or g==3 or (g==-2 and prioractive)))
 L-=int((726 if g<=-1 else 801)<=mm<=815);L+=int(821<=mm<=831 and g<=-1)+int(801<=mm<=831)
 L+=int(g>=-1 and (v('tma60diff')<-30 or v('tma20diff')<-30))
 L+=int(g in (-1,1) and count>=125 and phase not in (3,10,11) and boundary==2)
 L+=int(g>=3 and count>=125 and phase==11)+int(pp==9)
 return H,L,(1 if g==-2 else 0)

def cash_ok(price,balance,budget=6000000):
 fee=max(20,math.floor(price*1.425+.5));one=price*1000+fee;money=min(balance,budget)
 if money<one:return False
 qty=max(0,math.floor(money/(price*1000*1.001425)))
 if qty<math.ceil(20/(price*1.425)):qty=max(0,math.floor((money-20)/(price*1000)))
 if qty==0 and money>one:qty=1
 return qty>0

def load_original():
 Xs=[];keys=[];rounds=[]
 for lab in ('discovery','later'):
  x,k,rr=p3.dataset(lab)
  for r in rr:
   for f in ('entry','end','decline','trough'):
    if r[f] is not None:r[f]+=len(keys)
  Xs.append(x);keys+=k;rounds+=rr
 return np.concatenate(Xs),keys,rounds

def extract():
 assert not (O/'extraction-complete.json').exists()
 cat=read(P/'feature-catalog.json');names=[c['name'] for c in cat];cols={v:i for i,v in enumerate(names)}
 X,keys,rounds=load_original();lookup={(k['sample'],k['window'],k['stock'],k['date']):i for i,k in enumerate(keys)}
 anchors={(r['sample'],r['window'],r['stock'],r['entry_date']):r for r in rounds}
 ms=p.market_inputs();market={d:dict(row) for d,row in ms[2].items()}
 # Exact current-day market high9 from the already frozen market technical table.
 for day,m in market.items():
  raw=ms[1].get(day);tech=ms[0].get(day)
  m['is_high9']=bool(raw and tech and float(raw['high'])==float(tech['market_high_max_9']))
 paths=[];mat=[];audit=Counter();mismatches=[];scols=[i for i,c in enumerate(cat) if c['group']=='S'];warnings=[i for i,c in enumerate(cat) if c['name'].startswith('prior_warning_')]
 for sample in 'AB':
  events,fits=p.baseline_events(sample)
  with h.db(h.basedir(sample)/'decisions.sqlite') as db:
   levents={(r['window_id'],r['stock_id'],r['trade_date']):dict(r) for r in db.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=2')}
  for w,(fn,start,end) in h.WINDOWS.items():
   with h.db(h.reportdir(sample)/fn) as db:
    for st0 in db.execute('select * from ZSTOCK'):
     st=dict(st0);raw=[dict(r) for r in db.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],))]
     penalty=0;boundary=None;ema=[None]*4;slen=0;lastphase=None
     for i,r in enumerate(raw):
      day=h.dateof(r['ZDATETIME']);key=(w,st['ZSID'],day);e=events.get(key);fit=fits.get(key);prior=raw[i-1] if i else None
      phase=0;preview=None
      if e and prior:
       roi=e['roll_roi_before']/p.years(day,start);dd=p.avdays(e['roll_rounds_before'],e['roll_days_before'],e['inventory_before'],e['holding_days_before'])
       preview=p.fit_update(p.ownstate(prior),p.level_of(roi,dd),roi,dd);phase=preview[0]
       slen=slen+1 if phase and phase==lastphase else int(bool(phase));lastphase=phase
       if e['inventory_before']==0:
        g=grade(roi,dd,e['roll_rounds_before'],penalty,phase)
        H,L,ht=votes(r,prior,g,phase,preview[2],preview[1],p.ownstate(prior),penalty,boundary,market.get(day))
        audit['baselineFlatH']+=1
        if (g,H,ht)!=(e['grade'],e['decision_score'],e['decision_threshold']):mismatches.append(dict(key=[sample,*key],actual=[g,H,ht],expected=[e['grade'],e['decision_score'],e['decision_threshold']]))
        le=levents.get(key)
        if le:
         audit['baselineFlatL']+=1
         if L!=le['decision_score']:mismatches.append(dict(key=[sample,*key],actualL=L,expectedL=le['decision_score']))
      a=anchors.get((sample,w,st['ZSID'],day))
      if a:
       assert e['inventory_before']==0 and e['planned_action']=='H' and e['executed_action']=='BUY'
       pr=p.ownstate(prior);rollroi=e['roll_roi_before'];rd=e['roll_days_before'];nr=e['roll_rounds_before'];balance=e['balance_before'];em=ema.copy();bound=boundary;duration=slen;last=phase
       # Hypothetically refuse every purchase to expose all eligible dates. Each tested gate stops at its first fill.
       rows=[];features=[];prevf=X[lookup[(sample,w,st['ZSID'],h.dateof(prior['ZDATETIME']))]] if (sample,w,st['ZSID'],h.dateof(prior['ZDATETIME'])) in lookup else np.full(len(cat),np.nan)
       for j in range(i,min(i+11,len(raw))):
        q=raw[j];date=h.dateof(q['ZDATETIME']);k=(sample,w,st['ZSID'],date)
        if date>=end or k not in lookup:break
        d=j-i;z=X[lookup[k]].copy();roi=rollroi/p.years(date,start);dd=p.avdays(nr,rd,0,0);level=p.level_of(roi,dd)
        ph,ex,ct,fa,sl,tr=p.fit_update(pr,level,roi,dd);g=grade(roi,dd,nr,penalty,ph)
        H,L,ht=votes(q,raw[j-1],g,ph,ct,ex,pr,penalty,bound,market.get(date))
        if d==0:assert g==e['grade'] and H==e['decision_score']
        else:
         duration=duration+1 if ph and ph==last else int(bool(ph));last=ph
         z[scols]=np.nan
         f={'s_grade':g,'s_fit_level':level,'fit_evidence_days':rd,'fit_evidence_rounds':nr,'balance_before':balance,'roll_roi_before':rollroi,'decision_average_days':dd,'decision_annual_roi':roi,'decision_base_roi':100*prior['ZROLLAMTPROFIT']/(st['ZSIMMONEYBASE']*10000*(st['ZSIMINVESTAUTO']+1))/p.years(date,start),'gradeLossCutPenaltyLevel':penalty,'lastWorseningBoundary':bound or np.nan,'pre_roll_cost':prior['ZROLLAMTCOST'],'pre_roll_profit':prior['ZROLLAMTPROFIT'],'pre_money_lacked_cumulative':prior['ZSIMMONEYLACKEDCUMULATIVE'],'pre_invest_exceed_cumulative':prior['ZSIMINVESTEXCEEDCUMULATIVE']}
         if pr[2]>=125:
          f.update(s_fit_trend=pr[5],s_roi_trend=em[0]-em[1] if em[0] is not None else np.nan,s_days_trend=em[2]-em[3] if em[2] is not None else np.nan,prior_fit_fast=pr[0],prior_fit_slow=pr[1],prior_fit_trend_phase=pr[3] if pr[3] not in (0,4,5) else np.nan,prior_fit_trend_phase_extreme=pr[4])
         if ct>=125 and ph:
          f.update(decision_fit_phase=ph,decision_fit_extreme=ex,s_phase_duration=duration)
          if ph in (8,10) and ex is not None:f['decision_fit_late']=float(ex>=.911888 if ph==8 else ex<=-.911888)
         if g!=0 and (nr>2 or dd>360):
          for name,val in f.items():z[cols[name]]=val if p.finite(val) else np.nan
          for name in ('s_fit_level','s_fit_trend'):z[cols['delta_'+name]]=z[cols[name]]-prevf[cols[name]]
        can=cash_ok(q['ZPRICECLOSE'],balance,st['ZSIMMONEYBASE']*10000)
        # Anchor is an already executed original H so cooldown/manual gates have passed. Future flat days have no sale.
        rows.append(dict(date=date,wait=d,price=q['ZPRICECLOSE'],h=H>=ht and can,l=L>=5 and can,hScore=H,lScore=L,hThreshold=ht,grade=g,phase=ph,finiteFeatures=int(np.isfinite(z).sum())))
        features.append(z);prevf=z
        pr=(fa,sl,ct,ph,ex,tr)
        if dd>0:
         for n,v in enumerate((roi,roi,dd,dd)):em[n]=v if em[n] is None else em[n]+2/(21 if n%2==0 else 126)*(v-em[n])
        if ph==3:bound=1
        elif ph in (5,10,11):bound=2
       offset=len(mat);mat+=features
       paths.append(dict(id=a['id'],sample=sample,window=w,stock=st['ZSID'],entry=day,price=a['entry_price'],originalExit=a['end_date'],closed=a['closed'],offset=offset,days=rows,complete10=len(rows)==11,eligibleLower10=any(r['price']<a['entry_price'] and (r['h'] or r['l']) for r in rows[1:]),rawLower10=any(r['price']<a['entry_price'] for r in rows[1:])))
       audit['anchors']+=1
      if r['ZSIMQTYSELL']>0 and not r['ZSIMREVERSED']:
       if r['ZSIMAMTROI']<0:penalty=1
       elif r['ZSIMAMTROI']>0:penalty=0
      post=r['ZSIMFITTRENDPHASERAW']
      if post==3:boundary=1
      elif post in (5,10,11):boundary=2
      if day>=start and p.days_after(r)>0:
       for n,v in enumerate((p.annual(r,start),p.annual(r,start),p.days_after(r),p.days_after(r))):ema[n]=v if ema[n] is None else ema[n]+2/(21 if n%2==0 else 126)*(v-ema[n])
   print('FLAT',sample,w,'anchors',len(paths),'rows',len(mat),'control mismatches',len(mismatches),flush=True)
 save('extraction-control.json',dict(checks=dict(audit),mismatches=mismatches[:100],mismatchCount=len(mismatches)))
 assert not mismatches, 'H/L controls differ; do not accept analysis'
 assert len(paths)==1597
 Z=np.array(mat);known=read(R/'exports/h-entry-composite-shortwait-20260929/unique-flat-paths.json');priorX=np.load(P/'candidate-flat.npz')['X'];priorKeys=read(P/'candidate-flat-keys.json');knownmap={(k['anchor'],k['date']):i for i,k in enumerate(priorKeys)};pathmap={a['id']:a for a in paths};checked=0;fieldbad=[]
 for a in known:
  new=pathmap[a['id']]
  for d in a['days'][:11]:
   nd=next(t for t in new['days'] if t['date']==d['date']);assert nd['h']==d['hFeasible'],(a['id'],d,nd)
   assert not nd['l'] or d['lFill'] or d['hFeasible'],(a['id'],d,nd)
   b=priorX[knownmap[a['id'],d['date']]];z=Z[new['offset']+nd['wait']];validcols=np.ones(len(cat),bool)
   if nd['wait']>0:validcols[warnings]=False
   good=np.isclose(b,z,rtol=1e-10,atol=1e-8,equal_nan=True)|~validcols
   if not good.all():fieldbad.append(dict(id=a['id'],date=d['date'],fields=[names[i] for i in np.where(~good)[0]],old=b[~good].tolist(),new=z[~good].tolist()))
   checked+=1
 if fieldbad:
  (O/'flat-field-errors.json').write_text(json.dumps(fieldbad[:40],ensure_ascii=False,indent=2))
 assert not fieldbad,'flat S features differ from known candidate source'
 np.savez_compressed(O/'flat.npz',X=Z);save('paths.json',paths);save('feature-catalog.json',cat)
 save('extraction-complete.json',dict(anchors=len(paths),rows=len(Z),knownFlatRowsChecked=checked,originalHPrestates=1597,controls=dict(audit),futureWarningFieldsUnavailable=len(warnings),columns=names,files={f:h.sha(O/f) for f in ['flat.npz','paths.json','feature-catalog.json','extraction-control.json']}))
 print('EXTRACTION PASSED',len(paths),len(Z),checked,flush=True)



class Screen:
 def __init__(self,paths):
  self.paths=paths;self.n=n=len(paths);self.full=(1<<n)-1
  self.H=[];self.L=[];self.low=[];self.high=[];self.exists=[]
  for d in range(11):
   rows=[r['days'][d] if len(r['days'])>d else None for r in paths]
   self.H.append(eng.bits([bool(t and t['h']) for t in rows]));self.L.append(eng.bits([bool(t and t['l']) for t in rows]))
   self.low.append(eng.bits([bool(t and t['price']<r['price']) for t,r in zip(rows,paths)]))
   self.high.append(eng.bits([bool(t and t['price']>r['price']) for t,r in zip(rows,paths)]))
   self.exists.append(eng.bits([t is not None for t in rows]))
  self.oracle=eng.bits([r['eligibleLower10'] for r in paths])
  self.cells={s+str(w):eng.bits([r['sample']==s and r['window']==w for r in paths]) for s in 'AB' for w in sorted({r['window'] for r in paths})}
 def calc(self,m,v,details=False):
  hit=m&self.full;remain=hit;nh=hit.bit_count();good=dear=equal=unknown=sameday=0;goodmask=0;fills=[]
  if nh==0:return dict(hits=0,good=0,precision=0,tier=0,remaining=0)
  for d in range(11):
   sig=(m>>(d*self.n))&self.full;valid=(v>>(d*self.n))&self.full
   fill=remain&(((~sig)&self.H[d])|self.L[d]);remain&=~fill
   if not fill:continue
   known=fill&(valid|self.L[d]);unk=fill&~known;unknown+=unk.bit_count()
   if d==0:sameday+=known.bit_count()
   else:
    gm=known&self.low[d];good+=gm.bit_count();goodmask|=gm
    dear+=(known&self.high[d]).bit_count();equal+=(known&~(self.high[d]|self.low[d])).bit_count()
   if details:fills.append((d,fill,known))
  assert good+dear+equal+unknown+sameday+remain.bit_count()==nh
  z=dict(hits=nh,good=good,precision=good/nh,tier=2 if good==nh else 1 if good/nh>=.95 else 0,dearer=dear,equal=equal,unknown=unknown,sameDay=sameday,remaining=remain.bit_count(),oracle=(hit&self.oracle).bit_count())
  if details:z.update(hitmask=hit,goodmask=goodmask,fills=fills,cellHits={c:(hit&v).bit_count() for c,v in self.cells.items()})
  return z
 def rank(self,m,v):
  z=self.calc(m,v)
  return (z['tier'],round(z['precision'],10),z['good'],z['hits'])

def search_context(windows):
 comp=read(O/'extraction-complete.json')
 for f,dig in comp['files'].items():assert h.sha(O/f)==dig,f
 paths=[r for r in read(O/'paths.json') if r['window'] in windows];Z=np.load(O/'flat.npz')['X'];cat=read(O/'feature-catalog.json');defs=read(P/'atoms-no-outcome-ranking.json')
 obs=np.full((11*len(paths),len(cat)),np.nan)
 for j,r in enumerate(paths):
  for d in range(len(r['days'])):obs[d*len(paths)+j]=Z[r['offset']+d]
 atoms=[eng.Atom(**a,mask=eng.bits(m),valid=eng.bits(v)) for a,(m,v) in zip(defs,p3.arrays(defs,obs,cat))]
 return atoms,Screen(paths),defs,obs

def choose(nodes,atoms,width=180):
 families=Counter();pool=[]
 for n in sorted(nodes,key=lambda n:n.score,reverse=True):
  f=tuple(sorted({atoms[i].parent for b in n.expr for i in b}))
  if families[f]>=2:continue
  families[f]+=1;pool.append(n)
 return eng.choose(pool,width,max(1,width//9))

def search():
 assert not (O/'frozen.json').exists(),'Do not repeat frozen search'
 atoms,sc,defs,obs=search_context((1,2));reservoir=eng.Reservoir(120);counts=Counter();strata=defaultdict(Counter);passcounts=defaultdict(Counter);start=time.monotonic();retained=[];generated=set()
 def progress(stage,i):
  z=dict(stage=stage,index=i,expressions=sum(counts.values()),counts=dict(counts),seconds=round(time.monotonic()-start,2));save('progress.json',z);print(json.dumps(z),flush=True)
 def consider(expr,stage):
  if stage!='AND2':
   expr=tuple(sorted(tuple(sorted(b)) for b in expr))
   if expr in generated:return
   generated.add(expr)
  n=eng.make_node(expr,atoms,sc.rank)
  if n is None:return
  counts[stage]+=1;strata[stage][n.stratum]+=1
  assert sum(counts.values())<=4000000
  if n.score[0]:passcounts[stage][str(n.score[0])]+=1
  reservoir.add(n)
 for i,a in enumerate(atoms):
  for j in range(i+1,len(atoms)):
   if a.parent!=atoms[j].parent:consider(((i,j),),'AND2')
  if i%25==0:progress('AND2',i)
 pool=choose(reservoir.values(),atoms,180);retained+=pool;save('and2.json',dict(complete=True,counts=dict(counts),nodes=[dict(expr=n.expr,score=n.score,stratum=n.stratum) for n in pool]))
 for size in (3,4):
  parents=pool
  for q,n in enumerate(parents):
   if len(n.expr)!=1 or len(n.expr[0])!=size-1:continue
   used={atoms[i].parent for i in n.expr[0]}
   for a in atoms:
    if a.parent not in used:consider((n.expr[0]+(a.id,),),f'AND{size}')
   if q%10==0:progress(f'AND{size}',q)
  # Also carry lower-order candidates; only exact size extends in next stage.
  pool=choose(reservoir.values(),atoms,180);retained+=pool
  save(f'and{size}.json',dict(complete=True,counts=dict(counts),nodes=[dict(expr=n.expr,score=n.score,stratum=n.stratum) for n in pool]))
 branches=choose(reservoir.values(),atoms,180)
 for i,n in enumerate(branches):
  if len(n.expr)!=1:continue
  for m in branches[i+1:]:
   if len(m.expr)==1:consider((n.expr[0],m.expr[0]),'OR')
  if i%25==0:progress('OR',i)
 pool=choose(reservoir.values(),atoms,300);retained+=pool
 unique={n.expr:n for n in retained};ordered=sorted(unique.values(),key=lambda n:n.score,reverse=True)
 # Freeze a diagnostic shortlist before consulting known W3. Signal-overlap filter is train-only.
 chosen=[];signals=[]
 for n in ordered:
  if n.score[0]==0:continue
  hit=n.mask&sc.full
  if any((hit&old).bit_count()/max(1,(hit|old).bit_count())>=.75 for old in signals):continue
  chosen.append(dict(id=f'HC-Q10-{len(chosen)+1:02}',expr=n.expr,expression=p3.expression(n.expr,defs),stratum=n.stratum,training=sc.calc(n.mask,n.valid),score=n.score));signals.append(hit)
  if len(chosen)==12:break
 save('search-results.json',dict(complete=True,total=sum(counts.values()),counts=dict(counts),strata={k:dict(v) for k,v in strata.items()},passCounts={k:dict(v) for k,v in passcounts.items()},retained=[dict(expr=n.expr,score=n.score,stratum=n.stratum,metrics=sc.calc(n.mask,n.valid)) for n in ordered],seconds=time.monotonic()-start))
 save('frozen.json',dict(candidates=chosen,searchSHA=h.sha(O/'search-results.json'),selection='W1/W2 only; W3 known historically but not used in this search; twelve diagnostic candidates, at most six proposals',atomsSHA=h.sha(P/'atoms-no-outcome-ranking.json')))
 progress('complete',len(chosen));print([(c['id'],c['expression'],c['training']) for c in chosen],flush=True)

if __name__=='__main__':globals()[sys.argv[1]]()
