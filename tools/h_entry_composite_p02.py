#!/usr/bin/env python3
"""HC-P02: causal feature extraction and provenance only; no hypothesis scoring/replay."""
from pathlib import Path
import json, math, collections, sys, csv, hashlib, statistics
import numpy as np
import h_entry_composite as h
R=Path(__file__).resolve().parents[1];O=R/'exports/h-entry-composite-p02-20260929';P01=R/'exports/h-entry-composite-p01-20260929';OLD=h.OUT
NAN=float('nan')
# P01's remaining source rows: causal representations fixed before reading their new values.
WARNING_CATS={'status':{'normal':1,'caution':2,'recovering':3,'released':4},'prewarningReason':{'returnWeakness':1,'priceBottom':2,'both':3},'localReleaseReason':{'breakout':1,'stableProfit':2}}
WARNING_BOOL={'priceRecovered','recentReturnRecovered','gradeSeekingPeak','maRecoveryConfirmed','stableRecoveryConfirmed','isPrewarning','isWarning'}
WARNING_FIELDS=['status','priorAnnual','recoveryFloor','priceRecovered','recentReturnRecovered','gradeSeekingPeak','warningPriceHigh','prewarningFailureDays','prewarningReason','maRecoveryConfirmed','stableRecoveryConfirmed','localReleaseReason','isPrewarning','isWarning','recoveryGap']
def supplemental_catalog():
 out=[]
 for name in WARNING_FIELDS:
  c=dict(name='prior_warning_'+name,group='S',parent='prior_warning_'+name,kind='category' if name in WARNING_CATS else 'boolean' if name in WARNING_BOOL else 'continuous',source='previous Trade.simAnnualWarningData validated format=5, T3/S57, matching stock configuration',timing='previous completed Snapshot; its internal priorAnnual retains original extra lag',family='S')
  if name in WARNING_CATS:c['values']=list(WARNING_CATS[name].values())
  out.append(c)
 for name,kind in [('pre_roll_cost','continuous'),('pre_roll_profit','continuous'),('pre_money_lacked_cumulative','boolean'),('pre_invest_exceed_cumulative','continuous')]:out.append(dict(name=name,group='S',parent=name,kind=kind,source='previous completed Trade carried forward before current decisions',timing='pre-decision carry-forward, never today settlement',family='S'))
 return out
def read(p):return json.loads(p.read_text())
def save(n,x):
 p=O/n;tmp=p.with_suffix(p.suffix+'.tmp');tmp.write_text(json.dumps(x,ensure_ascii=False,indent=2,allow_nan=False)+'\n');tmp.replace(p)
def finite(x):return x is not None and math.isfinite(x)
def phase_next(t,p,e,prev):
 if not finite(t):return 0,None
 if t>.611888:
  if p not in (4,8,9) or not finite(e):return 8,t
  if p==9:return (8,t) if t>e else (9,e)
  peak=max(e,t);return (9 if t<peak-.3 else 8),peak
 if t<-.611888:
  if p not in (5,10,11) or not finite(e):return 10,t
  if p==11:return (10,t) if t<e or (finite(prev) and t<prev-.3) else (11,e)
  low=min(e,t);return (11 if t>low+.3 else 10),low
 if abs(t)<.3:return 1,None
 if t>=.3:return (6 if p in (4,8,9,6) else 2),None
 return (7 if p in (5,10,11,7) else 3),None

def fit_update(prev,level,roi,days):
 fast,slow,count,phase,ext,trend=prev
 if not all(finite(v) for v in (level,roi,days)) or days<=0:return 0,None,count,fast,slow,trend
 if count==0 and fast is None and slow is None:fast=slow=level;count=1
 elif count>0 and finite(fast) and finite(slow):fast+=2/21*(level-fast);slow+=2/126*(level-slow);count+=1
 else:return 0,None,count,fast,slow,trend
 t=fast-slow;p,e=phase_next(t,phase,ext,trend);return p,e,count,fast,slow,t

def avdays(rounds,days,inventory,holding):
 if rounds<=1:return days
 prev=(days-(holding if inventory>0 else 0))/(rounds-(1 if inventory>0 else 0))
 return days/rounds if holding>prev else prev

def ownstate(r):return (r['ZSIMFITFAST'],r['ZSIMFITSLOW'],r['ZSIMFITOBSERVATIONCOUNT'],r['ZSIMFITTRENDPHASERAW'],r['ZSIMFITTRENDPHASEEXTREME'],r['ZSIMFITTREND'])
def years(day,start):return max(1,(h.datetime.strptime(str(day),'%Y%m%d')-h.datetime.strptime(str(start),'%Y%m%d')).days/365)
def annual(r,start):return r['ZROLLAMTROI']/years(h.dateof(r['ZDATETIME']),start)
def days_after(r):return avdays(r['ZROLLROUNDS'],r['ZROLLDAYS'],r['ZSIMQTYINVENTORY'],r['ZSIMDAYS'])
def level_of(roi,days):return (roi*100/days if roi>=0 else roi*days/100) if days>0 else 0

def catalog():
 cat=read(OLD/'feature-catalog.json');new=read(P01/'proposed-features.json')
 for c in cat:
  c['group']='S' if c['name'].startswith(('s_','delta_s_')) else 'M' if c['name'].startswith(('market_','delta_market_')) else 'T'
  c['warmup']='see field-contract.json; volume counts all eligible TWSE days including zero volume'
 for c in new:
  c=dict(c,parent=c['name'],family=c['group'],timing='same day causal; S uses pre-decision/prior-completed source',warmup='see field-contract.json')
  if c['kind']=='phase12':c['kind']='category';c['values']=[1,2,3,6,7,8,9,10,11]
  if c['kind']=='category3':c['kind']='category';c['values']=[1,2]
  cat.append(c)
 for name,g,parent in [('price_phase','T','price_path'),('market_phase','M','market_path')]:cat.append(dict(name=name,group=g,parent=parent,kind='category',values=list(range(1,10)),family=g,timing='same-day path, no raw ordering'))
 cat+=supplemental_catalog()
 assert len({c['name'] for c in cat})==len(cat)==285
 return cat

def market_inputs():
 m=h.csvmap(h.MARKET/'market-technical.csv');raw=h.csvmap(h.MARKET/'market-daily.csv');path=h.csvmap(h.PATHS)
 streak=0;prev=None
 for day,p in sorted(path.items()):
  phase=int(p['phase_raw']);streak=streak+1 if phase and phase==prev else (1 if phase else 0);prev=phase;p['duration']=streak
 return m,raw,path

def progress_values(phase,b,anchor,ext,close,prefix):
 d={prefix+'_path_'+p+'_progress':NAN for p in ('peak','pullback','bottom','rebound')}
 if phase not in range(2,10) or not all(finite(v) and v>0 for v in (b,anchor,ext,close)):return d
 if phase in (2,3):d[prefix+'_path_peak_progress']=(ext/anchor-1)/b
 if phase in (4,5):d[prefix+'_path_pullback_progress']=(ext-close)/ext/b
 if phase in (6,7):d[prefix+'_path_bottom_progress']=(anchor-ext)/anchor/b
 if phase in (8,9):d[prefix+'_path_rebound_progress']=(close-ext)/ext/b
 return d

def market_ready(name,m):
 if not m:return False
 for family in ('volume','value','transaction'):
  if name.startswith('market_'+family+'_'):return m['market_'+family+'_mature_250']=='true'
 return m['price_mature_250']=='true'

def values(raw,n,stock,start,e,fit,ms,context,audit,fixtures=None):
 r=raw[n];prev=raw[n-1] if n else None;day=h.dateof(r['ZDATETIME']);m,mr,mp=ms[0].get(day),ms[1].get(day),ms[2].get(day)
 f={};mature=n+1>=250;phase=r['ZTPRICEPATHPHASERAW'];close=r['ZPRICECLOSE']
 context['vol']+=int(r['ZDATASOURCE']=='TWSE');context['posvol']+=int(r['ZDATASOURCE']=='TWSE' and r['ZVOLUMECLOSE']>0)
 if r['ZDATASOURCE']=='TWSE' and r['ZVOLUMECLOSE']==0:audit['validZeroVolumeRows']+=1
 context['price_duration']=context['price_duration']+1 if phase and phase==context['last_price_phase'] else (1 if phase else 0);context['last_price_phase']=phase
 for name,col,_,_ in h.old.BASE_FEATURE_SPECS:f[name]=r[col] if mature and (not name.startswith('v_') or context['vol']>=250) else NAN
 for name,col,ext,family,_ in h.old.EXTREME_FLAG_SPECS:f[name]=float(r[col]==r[ext]) if mature and (not family.startswith('volume') or context['vol']>=250) else NAN
 for c in CAT:
  name=c['name']
  if name in (m or {}):f[name]=float(m[name]) if market_ready(name,m) else NAN
  if name.startswith('market_raw_'):
   key=name.removeprefix('market_raw_');v=mr.get(key) if mr else None;f[name]=float(v) if v not in (None,'') else NAN
 for prefix,ph in [('price',phase),('market',int(mp['phase_raw']) if mp else 0)]:
  for lab,codes in [('peak',(2,3)),('pullback',(4,5)),('bottom',(6,7)),('rebound',(8,9)),('late',(3,5,7,9))]:f[prefix+'_path_'+lab]=float(ph in codes) if ph else NAN
  f['price_phase' if prefix=='price' else 'market_phase']=ph if ph else NAN
 for c in NEW:
  name=c['name'];col='Z'+name.upper()
  if c['group']=='T' and col in r:
   ready=(phase!=0 if name.startswith('tPricePath') else mature and (not name.startswith(('v','volume')) or context['vol']>=250))
   f[name]=r[col] if ready and finite(r[col]) else NAN
 f['close_change_percent']=100*(close/prev['ZPRICECLOSE']-1) if prev and prev['ZPRICECLOSE']>0 else NAN
 f['stock_phase_duration']=context['price_duration'] if phase else NAN
 if prev and prev['ZPRICECLOSE']>0 and close>0:
  context['returns'].append(math.log(close/prev['ZPRICECLOSE']));context['returns']=context['returns'][-60:]
 else:context['returns']=[]
 rs=context['returns'];f['t_path_available_barrier']=min(.15,max(.05,statistics.stdev(rs)*math.sqrt(20))) if len(rs)>=40 else NAN
 for period in (20,60):f[f'ma{period}d']=r[f'ZTMA{period}DIFFMAX9']-r[f'ZTMA{period}DIFFMIN9'] if mature else NAN
 f['min9s']=sum(r['Z'+x]==r['Z'+x+'MIN9'] for x in ('TMA20DIFF','TMA60DIFF','TKDK','TOSC')) if mature else NAN
 f.update(progress_values(phase,r['ZTPRICEPATHBARRIER'],r['ZTPRICEPATHANCHORCLOSE'],r['ZTPRICEPATHEXTREMECLOSE'],close,'t'))
 pmap={'market_path_available_barrier':'available_barrier','market_path_barrier':'frozen_barrier','market_path_anchor':'anchor_close','market_path_extreme':'extreme_close','market_path_days_since_extreme':'days_since_extreme','market_phase_duration':'duration'}
 for name,key in pmap.items():f[name]=float(mp[key]) if mp and int(mp['phase_raw']) and mp.get(key) not in ('',None) else NAN
 f.update(progress_values(int(mp['phase_raw']) if mp else 0,f['market_path_barrier'],f['market_path_anchor'],f['market_path_extreme'],float(mr['close']) if mr else NAN,'m'))
 active=bool(e and fit and e['grade']!=0 and fit['grade_activation_passed'] and fit['is_finite'])
 f['s_grade']=e['grade'] if active else NAN;f['s_fit_level']=fit['fit_level'] if active else NAN
 for target,col in [('s_fit_trend','fit_trend'),('s_roi_trend','roi_trend'),('s_days_trend','days_trend')]:f[target]=fit[col] if active and fit['fit_observation_count']>=125 and finite(fit[col]) else NAN
 smap={'prior_fit_fast':'fit_fast','prior_fit_slow':'fit_slow','prior_fit_trend_phase':'fit_trend_phase','prior_fit_trend_phase_extreme':'fit_trend_phase_extreme','fit_evidence_days':'fit_evidence_days','fit_evidence_rounds':'fit_evidence_rounds'}
 for name,col in smap.items():
  v=fit[col] if fit else None;ready=active and (not name.startswith('prior_') or fit['fit_observation_count']>=125)
  f[name]=v if ready and finite(v) and (col!='fit_trend_phase' or v not in (0,4,5)) else NAN
 for name in ('balance_before','roll_roi_before'):f[name]=e[name] if active else NAN
 if e and prev:
  roi=e['roll_roi_before']/years(day,start);dd=avdays(e['roll_rounds_before'],e['roll_days_before'],e['inventory_before'],e['holding_days_before']);level=level_of(roi,dd)
  if fit:assert math.isclose(level,fit['fit_level'],abs_tol=1e-9,rel_tol=1e-12),(day,level,fit['fit_level']);audit['decisionFitLevelChecks']+=1
  pp,pe,pc,pf,ps,pt=fit_update(ownstate(prev),level,roi,dd)
  if fixtures is not None:fixtures.append(dict(key=[stock['ZSID'],start,day,'preview'],previous=list(ownstate(prev)),level=level,roi=roi,days=dd,expected=[pp,pe,pc,pf,ps,pt]))
  # Independently validate the same official state transition against already persisted POST values.
  postroi=annual(r,start);postdays=days_after(r);postlevel=level_of(postroi,postdays)
  post=fit_update(ownstate(prev),postlevel,postroi,postdays)
  if postdays>0:
   expect=[r['ZSIMFITTRENDPHASERAW'],r['ZSIMFITTRENDPHASEEXTREME'],r['ZSIMFITOBSERVATIONCOUNT'],r['ZSIMFITFAST'],r['ZSIMFITSLOW'],r['ZSIMFITTREND']]
   for x,y in zip(post,expect):assert x==y or (finite(x) and finite(y) and math.isclose(x,y,rel_tol=1e-12,abs_tol=1e-9)),(day,x,y)
   audit['persistedPostFitTransitions']+=1
  if fit:
   for col,v in zip(('fit_fast','fit_slow','fit_observation_count','fit_trend_phase','fit_trend_phase_extreme','fit_trend'),ownstate(prev)):
    a=fit[col];assert a==v or (finite(a) and finite(v) and math.isclose(a,v,abs_tol=1e-9,rel_tol=1e-12)),(col,day,a,v)
   audit['priorFitEqualsPreviousStored']+=1
  f['decision_average_days']=dd if active else NAN;f['decision_annual_roi']=roi if active else NAN
  f['decision_base_roi']=100*prev['ZROLLAMTPROFIT']/(stock['ZSIMMONEYBASE']*10000*(stock['ZSIMINVESTAUTO']+1))/years(day,start) if active else NAN
  context['s_duration']=context['s_duration']+1 if pp and pp==context['last_s_phase'] else (1 if pp else 0);context['last_s_phase']=pp
  f['decision_fit_phase']=pp if active and pc>=125 and pp else NAN;f['decision_fit_extreme']=pe if active and pc>=125 and pe is not None else NAN
  f['decision_fit_late']=(float(pe>=.911888) if pp==8 else float(pe<=-.911888)) if active and pc>=125 and pp in (8,10) and pe is not None else NAN
  f['s_phase_duration']=context['s_duration'] if active and pc>=125 and pp else NAN
  f['gradeLossCutPenaltyLevel']=context['penalty'] if active else NAN;f['lastWorseningBoundary']=context['boundary'] if active and context['boundary'] else NAN
  f['tradingDaysSinceLastInvestment']=context['invest_distance'] if active and context['invest_distance'] is not None else NAN
 else:
  for c in NEW:
   if c['group']=='S':f[c['name']]=NAN
 # Existing stored warning is readable as PREVIOUS completed snapshot, not current warning.
 for c in supplemental_catalog():f[c['name']]=NAN
 if active and prev:
  for name,col in [('pre_roll_cost','ZROLLAMTCOST'),('pre_roll_profit','ZROLLAMTPROFIT'),('pre_money_lacked_cumulative','ZSIMMONEYLACKEDCUMULATIVE'),('pre_invest_exceed_cumulative','ZSIMINVESTEXCEEDCUMULATIVE')]:f[name]=float(prev[col])
  blob=prev['ZSIMANNUALWARNINGDATA']
  if blob:
   rec=json.loads(blob);conf=rec['configuration']
   assert rec['formatVersion']==5 and rec['dataRules']=='T3/S57' and conf['start']==stock['ZDATESTART'] and conf['budget']==stock['ZSIMMONEYBASE'] and conf['additions']==stock['ZSIMINVESTAUTO']
   snap=dict(rec['snapshot']);status=snap['status']
   snap['isPrewarning']=status in ('normal','released') and snap.get('prewarningFailureDays') is not None
   snap['isWarning']=status in ('caution','recovering') or snap['isPrewarning']
   snap['recoveryGap']=max(0,snap['recoveryFloor']-snap['priorAnnual']) if all(finite(snap.get(x)) for x in ('recoveryFloor','priorAnnual')) else None
   for name in WARNING_FIELDS:
    v=snap.get(name);value=WARNING_CATS[name].get(v) if name in WARNING_CATS else v
    f['prior_warning_'+name]=float(value) if status!='unavailable' and value is not None else NAN
 # Past-only context advances AFTER collecting today's pre-decision features.
 if r['ZSIMQTYSELL']>0 and not r['ZSIMREVERSED']:
  if r['ZSIMAMTROI']<0:context['penalty']=1
  elif r['ZSIMAMTROI']>0:context['penalty']=0
 postphase=r['ZSIMFITTRENDPHASERAW']
 if postphase==3:context['boundary']=1
 elif postphase in (5,10,11):context['boundary']=2
 if r['ZSIMINVESTBYUSER']+r['ZSIMINVESTADDED']==1:context['invest_distance']=0
 elif r['ZSIMDAYS']<=1:context['invest_distance']=None
 elif context['invest_distance'] is not None:context['invest_distance']+=1
 for name in h.DELTAS:f['delta_'+name]=f[name]-context['prev_f'].get(name,NAN)
 context['prev_f']=dict(f)
 return f

def ctx():return dict(vol=0,posvol=0,returns=[],price_duration=0,last_price_phase=None,s_duration=0,last_s_phase=None,penalty=0,boundary=None,invest_distance=None,prev_f={})
def baseline_events(sample):
 with h.db(h.basedir(sample)/'decisions.sqlite') as c:
  events={(e['window_id'],e['stock_id'],e['trade_date']):dict(e) for e in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=1')}
  fits={(e['window_id'],e['stock_id'],e['trade_date']):dict(e) for e in c.execute('select e.*,s.stock_id from strategy_fit_observations e join stocks s using(stock_key)')}
 return events,fits

def extract():
 global CAT,NEW
 assert not (O/'completion.json').exists();CAT=catalog();NEW=read(P01/'proposed-features.json');save('feature-catalog.json',CAT)
 names=[c['name'] for c in CAT];ms=market_inputs();fixtures=[];audit=collections.Counter();warning=[];metadata=[];output={};baseline_inputs={}
 for label in ('discovery','later'):
  keys=read(OLD/f'{label}-keys.json');output[label]=np.full((len(keys),len(CAT)),NAN);baseline_inputs[label]=np.load(OLD/f'{label}.npz')['X']
  for i,k in enumerate(keys):metadata.append((label,i,k))
 lookup={(k['sample'],k['window'],k['stock'],k['date']):(label,i) for label,i,k in metadata}
 assert len(lookup)==43802
 for sample in 'AB':
  events,fits=baseline_events(sample)
  for w,(fn,start,end) in h.WINDOWS.items():
   with h.db(h.reportdir(sample)/fn) as c:
    for st in c.execute('select * from ZSTOCK'):
     stock=dict(st);raw=[dict(r) for r in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],))];context=ctx()
     for n,r in enumerate(raw):
      day=h.dateof(r['ZDATETIME']);key=(w,stock['ZSID'],day);e=events.get(key);fit=fits.get(key)
      f=values(raw,n,stock,start,e,fit,ms,context,audit,fixtures if e else None)
      target=lookup.get((sample,*key))
      if target:
       label,i=target;output[label][i]=[f.get(name,NAN) if finite(f.get(name)) else NAN for name in names];audit['rows']+=1
       # Decode only for provenance/descriptive archive. Never include post-trade warning as input.
       blob=r['ZSIMANNUALWARNINGDATA'];rec=json.loads(blob) if blob else None
       if rec:
        assert rec['formatVersion']==5 and rec['dataRules']=='T3/S57';conf=rec['configuration'];assert conf['budget']==stock['ZSIMMONEYBASE'] and conf['additions']==stock['ZSIMINVESTAUTO'] and conf['start']==stock['ZDATESTART']
        warning.append(dict(sample=sample,window=w,stock=stock['ZSID'],date=day,timing='after current simulation; descriptive only',snapshot=rec['snapshot']));audit['warningDecoded']+=1
       audit['zeroVolumeMaturityChangedRows']+=int((context['vol']>=250)!=(context['posvol']>=250))
   print(f'EXTRACT {sample} W{w}: {audit["rows"]} rows, {audit["persistedPostFitTransitions"]} S transitions',flush=True)
 assert audit['rows']==43802
 changes={}
 for label,X in output.items():
  old=baseline_inputs[label];byfield={}
  for j,c in enumerate(CAT[:160]):
   same=(X[:,j]==old[:,j])|(np.isnan(X[:,j])&np.isnan(old[:,j]));changed=int((~same).sum())
   if changed:
    assert c['group'] in ('M','T') and (c['name'].startswith(('v_','delta_v_','market_','delta_market_','volume_'))),c['name']
    byfield[c['name']]=dict(changed=changed,newlyAvailable=int((np.isfinite(X[:,j])&~np.isfinite(old[:,j])).sum()),valueChanged=int((np.isfinite(X[:,j])&np.isfinite(old[:,j])&(X[:,j]!=old[:,j])).sum()))
  changes[label]=byfield
  np.savez_compressed(O/f'{label}.npz',X=X)
 save('maturity-diff.json',changes);save('s-preview-fixtures.json',fixtures);save('warning-descriptive.json',warning);save('extraction-audit.json',dict(audit))
 availability=[]
 for j,c in enumerate(CAT):
  row=dict(name=c['name'],group=c['group'],parent=c['parent'],kind=c['kind'])
  for label,X in output.items():
   rounds=read(OLD/f'{label}-rounds.json');entry=[r['entry'] for r in rounds]
   row[label]=dict(finite=int(np.isfinite(X[:,j]).sum()),rows=len(X),entryFinite=int(np.isfinite(X[entry,j]).sum()),entries=len(entry))
  availability.append(row)
 save('availability.json',availability)
 save('extraction-complete.json',dict(columns=names,files={n:h.sha(O/n) for n in ('feature-catalog.json','discovery.npz','later.npz','s-preview-fixtures.json','availability.json')}))
 print('EXTRACTION COMPLETE',dict(audit),flush=True)
if __name__=='__main__':extract()
