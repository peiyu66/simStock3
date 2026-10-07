#!/usr/bin/env python3
"""LD-P02 numeric extractor, derived from SD-P02 values().
Only warning identity changes S59 -> S61. No strategy replay or source writes.
CAT and NEW are injected by the bounded LD-P02 caller.
"""
import json, math, statistics
import h_entry_composite as h
from h_entry_composite_p02 import (finite, fit_update, avdays, ownstate,
    years, annual, days_after, level_of, progress_values, market_ready,
    supplemental_catalog, WARNING_FIELDS, WARNING_CATS)
NAN=float('nan')
CAT=[]
NEW=[]

def values(raw,n,stock,start,e,fit,ms,context,audit,fixtures=None, verify_post=True):
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
  if postdays>0 and verify_post:
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
   assert rec['formatVersion']==5 and rec['dataRules']=='T3/S61' and conf['start']==stock['ZDATESTART'] and conf['budget']==stock['ZSIMMONEYBASE'] and conf['additions']==stock['ZSIMINVESTAUTO']
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
