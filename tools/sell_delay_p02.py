#!/usr/bin/env python3
"""SD-P02: v35 sell opportunity data and causal controls; no condition scoring/replay.

The feature extractor derives from HC-P02, with T3/S59 warning identity and a
SELL-specific outer contract. Old research files and matrices are never written.
"""
from pathlib import Path
import collections, copy, csv, hashlib, json, math, statistics, subprocess, time
import numpy as np
import h_entry_composite as h
import h_entry_composite_p02 as prior
import h_entry_composite_search as atoms_tool
import market_technical as mt
from h_entry_composite_p02 import (finite, phase_next, fit_update, avdays, ownstate,
    years, annual, days_after, level_of, progress_values, market_ready, ctx,
    supplemental_catalog, WARNING_FIELDS, WARNING_CATS)
R=Path(__file__).resolve().parents[1]
P01=R/'exports/sell-delay-p01-20260930'
O=R/'exports/sell-delay-p02-20260930'
RULE='6097cc26fe839dd8878082ac8f11bdaf08cf0306'
NAN=float('nan')
CAT=[]
NEW=[]
SOURCES={}

def sha(path):return h.sha(path)
def read(path):return json.loads(Path(path).read_text())
def save(name,data):
    path=O/name;path.parent.mkdir(parents=True,exist_ok=True)
    temp=path.with_suffix(path.suffix+'.tmp')
    temp.write_text(json.dumps(data,ensure_ascii=False,indent=2,allow_nan=False)+'\n');temp.replace(path)
def protect(path):
    path=Path(path);SOURCES[str(path.relative_to(R))]=sha(path)

def warning_valid(blob,stock):
    if not blob:return False
    rec=json.loads(blob)
    assert rec['formatVersion']==5 and rec['dataRules']=='T3/S59'
    assert rec['configuration']==dict(start=stock['ZDATESTART'],budget=stock['ZSIMMONEYBASE'],additions=stock['ZSIMINVESTAUTO'])
    snap=rec['snapshot'];floor=rec.get('continuationFloor');high=rec.get('continuationPriceHigh')
    assert (finite(floor) and finite(high) and high>0) if floor is not None else (high is None and not rec['locallyReleased'])
    assert rec['locallyReleased']==(snap.get('localReleaseReason') is not None)
    fail=snap.get('prewarningFailureDays')
    if fail is not None:assert fail in (0,1,2) and snap['status'] in ('normal','released') and snap.get('prewarningReason') is not None
    else:assert snap.get('prewarningReason') is None
    assert snap['status'] in ('unavailable','normal','caution','recovering','released')
    return True

def net_sell(close,qty):
    gross=close*qty*1000
    # Swift round: nearest, ties away from zero; these fee/tax inputs are positive.
    return gross-max(20,math.floor(gross*.001425+.5))-math.floor(gross*.003+.5)

def opportunity(anchor,dates,closes,qty):
    assert len(dates)==len(closes)<=10 and all(finite(x) and x>0 for x in [anchor,*closes])
    changes=[100*(x/anchor-1) for x in closes]
    higher=[i for i,x in enumerate(closes) if x>anchor]
    maxprice=max(closes) if closes else None;minprice=min(closes) if closes else None
    peaks=[i for i,x in enumerate(closes) if x==maxprice]
    troughs=[i for i,x in enumerate(closes) if x==minprice]
    segments=[]
    for i in higher:
        if segments and segments[-1][-1]==i-1:segments[-1].append(i)
        else:segments.append([i])
    signs=[]
    for x in closes:
        sign='higher' if x>anchor else 'lower' if x<anchor else 'equal'
        if sign!='equal' and (not signs or sign!=signs[-1]):signs.append(sign)
    return dict(completeTen=len(closes)==10,observedHigher=bool(higher),
        fullOpportunity=(bool(higher) if len(closes)==10 else None),
        highestClose=maxprice,highestDates=[dates[i] for i in peaks],
        higherHighestDates=[dates[i] for i in peaks] if higher else [],
        firstHigherDate=dates[higher[0]] if higher else None,higherDays=len(higher),
        higherSegments=[[dates[i] for i in seg] for seg in segments],
        maxGainPct=max(changes) if changes else None,minGainPct=min(changes) if changes else None,
        lowestDates=[dates[i] for i in troughs],firstPeakOffset=peaks[0]+1 if peaks else None,
        pathTransitions=signs,
        minGainBeforeFirstPeakPct=min([0,*changes[:peaks[0]+1]]) if peaks else None,
        minGainAfterFirstPeakPct=min(changes[peaks[0]:]) if peaks else None,
        dailyGainPct=changes,netProceedsDelta=[net_sell(x,qty)-net_sell(anchor,qty) for x in closes])

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
   assert rec['formatVersion']==5 and rec['dataRules']=='T3/S59' and conf['start']==stock['ZDATESTART'] and conf['budget']==stock['ZSIMMONEYBASE'] and conf['additions']==stock['ZSIMINVESTAUTO']
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

def main():
    global CAT,NEW
    assert not (O/'completion.json').exists(), 'Completed SD-P02 evidence is immutable'
    O.mkdir(parents=True,exist_ok=True)
    save('protocol.json',dict(stage='SD-P02',status='running',authorization='User 好 to the sole SD-P02 proposal',task='01a0ef6d-ef8b-7aa2-9790-ea4fa9c48f79',baseline=35,decisionBase=21,dataRules='T3/S59',ruleCommit=RULE,rowsUpper=17632,fields=292,searches=0,strategyReplays=0,builds=0,downloads=0,simulatorOperations=0,CDEEffectsRead=False))
    # Verify immutable inputs, not just completion-marker presence.
    p1=read(P01/'completion.json');assert p1['status']=='complete' and p1['ruleCommit']==RULE
    for path,digest in {**read(P01/'source-hashes.json'),**p1['artifacts']}.items():
        assert sha(R/path)==digest,path
        # Plan is a mutable progress document; its P01 hash records that point in time.
        if path!='doc/延遲賣出複合規則研究計畫-20260930.md':protect(R/path)
    protect(P01/'completion.json')
    for path in ['tools/sell_delay_p02.py','tools/h_entry_composite.py','tools/h_entry_composite_p02.py','tools/h_entry_composite_search.py','tools/fwd_v20_path_discovery.py','tools/market_technical.py']:protect(R/path)
    assert subprocess.check_output(['git','rev-parse',RULE],cwd=R,text=True).strip()==RULE
    identities=read(P01/'identities.json');events=read(P01/'sell-events.json')
    CAT=[{k:v for k,v in c.items() if k not in ('oldBuyResearchSource','status','searched','warmup')} for c in read(P01/'feature-catalog.json')]
    for c in CAT:
        c.update(anchorRole='original SELL causal prestate' if c['group']=='S' else 'same-day market/stock input',futureRole='unknown candidate state; baseline values descriptive only' if c['group']=='S' else 'same-day input independent of trading',timing='current/prior data only; see field-contract.json')
        if c['name']=='buy_rule_before':c.update(values=[1,2],encoding={'H':1,'L':2})
    NEW=read(R/'exports/h-entry-composite-p01-20260929/proposed-features.json');protect(R/'exports/h-entry-composite-p01-20260929/proposed-features.json')
    names=[c['name'] for c in CAT];lookup={n:i for i,n in enumerate(names)};scols=[i for i,c in enumerate(CAT) if c['group']=='S']
    assert len(CAT)==292
    ms=prior.market_inputs()
    selected={(e['sample'],e['window'],e['stock_id'],day) for e in events for day in [e['trade_date'],*e['futureDates']]}
    anchors={(e['sample'],e['window'],e['stock_id'],e['trade_date']):e for e in events}
    feature_cache={};raw_cache={};audit=collections.Counter();errors=collections.defaultdict(float);fixtures=[]
    def same(a,b,label,tol=1e-8):
        assert a==b or (finite(a) and finite(b) and math.isclose(a,b,abs_tol=tol,rel_tol=1e-11)),(label,a,b)
        audit[label]+=1
        if isinstance(a,(int,float)) and isinstance(b,(int,float)) and finite(a) and finite(b):errors[label]=max(errors[label],abs(a-b))
    for sample in 'AB':
        ident=identities[sample]
        with h.db(R/ident['decisionBase']/'decisions.sqlite') as db:
            ev={(e['window_id'],e['stock_id'],e['trade_date']):dict(e) for e in db.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=1')}
            fits={(e['window_id'],e['stock_id'],e['trade_date']):dict(e) for e in db.execute('select e.*,s.stock_id from strategy_fit_observations e join stocks s using(stock_key)')}
            sell={(e['window_id'],e['stock_id'],e['trade_date']):dict(e) for e in db.execute("select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=3 and executed_action='SELL'")}
        for w,(filename,start,end) in h.WINDOWS.items():
            with h.db(R/ident['report']/filename) as db:
                assert db.execute('pragma quick_check').fetchone()[0]=='ok'
                for st in db.execute('select * from ZSTOCK'):
                    stock=dict(st);assert stock['ZTECHNICALSTATEVERSION']==3 and stock['ZSIMULATIONSTATEVERSION']==59
                    assert stock['ZTECHNICALDIRTYFROM'] is None and stock['ZSIMULATIONDIRTYFROM'] is None
                    raw=[dict(r) for r in db.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(stock['Z_PK'],))]
                    dates=[h.dateof(r['ZDATETIME']) for r in raw];assert dates==sorted(set(dates))
                    context=ctx();previous_f=None
                    for n,r in enumerate(raw):
                        day=dates[n];key=(sample,w,stock['ZSID'],day);ekey=key[1:];e=ev.get(ekey);fit=fits.get(ekey)
                        before=copy.deepcopy(context) if key in anchors else None
                        f=values(raw,n,stock,start,e,fit,ms,context,audit)
                        # HOLDING extras are meaningful independently of Grade activation.
                        for name in ('inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before'):
                            f[name]=e[name] if e and e['inventory_before']>0 else NAN
                        f['buy_rule_before']={'H':1.,'L':2.}.get(e['buy_rule_before'],NAN) if e and e['inventory_before']>0 else NAN
                        f['holding_cost_before']=raw[n-1]['ZSIMAMTCOST'] if e and n and e['inventory_before']>0 else NAN
                        assert set(names)<=set(f),(key,sorted(set(names)-set(f)))
                        if key in anchors:
                            a=anchors[key];se=sell[ekey]
                            for field in ('grade','inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before','balance_before','roll_roi_before','roll_days_before','roll_rounds_before','buy_rule_before'):
                                same(e[field],se[field],'HBDecisionEqualsSELLPrestate',0)
                            same(before['invest_distance'],a['previousInvestmentGap'],'investmentGapMatchesP01',0)
                            same(net_sell(r['ZPRICECLOSE'],a['inventory_before'])-raw[n-1]['ZSIMAMTCOST'],r['ZSIMAMTPROFIT'],'originalSaleFeeTaxProfit')
                            # Poison current post-trade state and future rows; pre-decision inputs must not change.
                            changed=dict(r)
                            for col in r:
                                if col.startswith(('ZSIM','ZROLL')) and isinstance(r[col],(int,float)):changed[col]=123456789.
                            probe=raw[:n]+[changed,{'ZPRICECLOSE':-999}]
                            alt=values(probe,n,stock,start,e,fit,ms,copy.deepcopy(before),collections.Counter(),verify_post=False)
                            for c in CAT[:-7]:
                                x=f[c['name']];y=alt[c['name']]
                                assert x==y or (not finite(x) and not finite(y)),(key,c['name'],'poststate leak')
                            audit['poststateAndFuturePoisonControls']+=1
                        if key in selected:
                            assert start<=day<=end and r['ZPRICECLOSE']>0 and r['ZDATASOURCE']=='TWSE'
                            audit['selectedOfficialPositiveClose']+=1
                            if n and warning_valid(raw[n-1]['ZSIMANNUALWARNINGDATA'],stock):audit['priorWarningDecodeControls']+=1
                            # Independent source and representative formula checks on every selected day.
                            for name,col,_,_ in h.old.BASE_FEATURE_SPECS:
                                if finite(f[name]):same(f[name],r[col],'directTChecks',0)
                            for name,col,ext,_,_ in h.old.EXTREME_FLAG_SPECS:
                                if finite(f[name]):same(f[name],float(r[col]==r[ext]),'extremeFlagChecks',0)
                            for c in NEW:
                                col='Z'+c['name'].upper()
                                if c['group']=='T' and col in r and finite(f[c['name']]):same(f[c['name']],r[col],'addedDirectTChecks',0)
                            for name in ['tMa20DiffMax9','tMa20DiffMin9','tMa60DiffMax9','tMa60DiffMin9','tKdKMax9','tKdKMin9','tOscMax9','tOscMin9']:
                                if finite(f[name]):same(f[name],(max if 'Max9' in name else min)(q['Z'+name[:-4].upper()] for q in raw[max(0,n-8):n+1]),'nineDayExtremaChecks',0)
                            for period in (20,60):
                                name=f'tMa{period}'
                                if finite(f[name]):same(f[name],sum(q['ZPRICECLOSE'] for q in raw[max(0,n-period+1):n+1])/min(n+1,period),'movingAverageChecks')
                            for name in h.DELTAS:
                                if finite(f['delta_'+name]):same(f['delta_'+name],f[name]-previous_f[name],'oneDayDifferenceChecks',0)
                            feature_cache[key]=[f[name] if finite(f[name]) else NAN for name in names]
                            raw_cache[key]=dict(close=r['ZPRICECLOSE'],volume=r['ZVOLUMECLOSE'],source=r['ZDATASOURCE'],priceObservations=n+1,volumeObservations=context['vol'],marketPresent=day in ms[1],previousDate=dates[n-1] if n else None)
                        previous_f=f
            print(json.dumps(dict(progress=sample+str(w),selected=len(feature_cache),controls=dict(audit))),flush=True)
    assert set(feature_cache)==selected and len(selected)==13494
    # Recompute market numerical and maturity series from the frozen raw input.
    market_raw=list(csv.DictReader((h.MARKET/'market-daily.csv').open()))
    frozen=list(csv.DictReader((h.MARKET/'market-technical.csv').open()))
    calc=mt.calculate_market(market_raw);assert len(calc)==len(frozen)
    for actual,expected in zip(calc,frozen):
        assert actual['date']==expected['date']
        for name,value in actual.items():
            if name=='date':continue
            if isinstance(value,bool):assert ('true' if value else 'false')==expected[name];audit['marketMaturityRecomputed']+=1
            else:same(float(value),float(expected[name]),'marketNumericsRecomputed')
    # Extract outcome paths after features; never use outcomes to set cuts.
    all_ops=[];matrices={};keys_by_label={};anchor_arrays={}
    for label,windows in [('discovery',(1,2)),('later',(3,))]:
        keys=[];base=[];causal=[];oplist=[];entry=[]
        for a in events:
            if a['window'] not in windows:continue
            entry.append(len(keys));indices=[]
            for offset,day in enumerate([a['trade_date'],*a['futureDates']]):
                key=(a['sample'],a['window'],a['stock_id'],day);vals=feature_cache[key]
                safe=list(vals)
                if offset:
                    for j in scols:safe[j]=NAN
                indices.append(len(keys));base.append(vals);causal.append(safe)
                keys.append(dict(sample=key[0],window=key[1],stock=key[2],date=day,event=a['event_id'],anchor=a['trade_date'],offset=offset,**raw_cache[key]))
            prices=[keys[i]['close'] for i in indices]
            op=opportunity(prices[0],a['futureDates'],prices[1:],a['inventory_before'])
            op.update(sample=a['sample'],window=a['window'],stock=a['stock_id'],event=a['event_id'],anchor=a['trade_date'],exitRoute=a['exitRoute'],grade=a['grade'],originalClose=prices[0],inventory=a['inventory_before'],indices=indices,partition=label)
            oplist.append(op)
        X=np.array(causal,dtype=np.float64);B=np.array(base,dtype=np.float64);entries=np.array(entry,dtype=np.int64)
        future=np.array([k['offset']>0 for k in keys]);assert np.isnan(X[future][:,scols]).all()
        np.savez_compressed(O/f'{label}.npz',X=X,valid=np.isfinite(X),anchors=entries)
        np.savez_compressed(O/f'{label}-baseline-descriptive.npz',X=B,valid=np.isfinite(B))
        save(f'{label}-keys.json',keys);save(f'{label}-opportunities.json',oplist)
        matrices[label]=X;keys_by_label[label]=keys;anchor_arrays[label]=X[entries];all_ops+=oplist
    assert len(all_ops)==1609 and sum(len(v) for v in keys_by_label.values())==17632
    availability=[];contracts=[]
    oldcat={c['name']:c for c in read(P01/'feature-catalog.json')}
    for j,c in enumerate(CAT):
        stats={label:dict(anchors=len(X),finite=int(np.isfinite(X[:,j]).sum()),distinct=int(len(np.unique(X[np.isfinite(X[:,j]),j])))) for label,X in anchor_arrays.items()}
        availability.append(dict(name=c['name'],group=c['group'],**stats))
        historical=oldcat[c['name']].get('oldBuyResearchSource',{})
        maturity=('original Grade active and finite; trends >=125; warning available/valid; inactive phases missing' if c['group']=='S' else 'stock technical >=250; volume >=250 eligible TWSE including zero; path nonzero; market respective mature250; raw market same date')
        if c['name'] in names[-7:]:maturity='original decision inventory >0; positive unit cost for cost/ROI; H=1 L=2 unordered'
        if c['name']=='tradingDaysSinceLastInvestment':maturity+='; no applicable investment is missing, never zero'
        contracts.append(dict(column=j,name=c['name'],group=c['group'],parent=c['parent'],kind=c['kind'],source=c.get('source'),formula=historical.get('formula',c.get('source')),maturity=maturity,anchorRole=c['anchorRole'],futureRole=c['futureRole'],missingPolicy='NaN with validity mask; unknown never zero or counterexample repair',availability=stats))
    save('feature-catalog.json',CAT);save('field-contract.json',contracts);save('availability.json',availability)
    # Numeric-only atom generation on original SELL anchors in W1/W2, never W3 or outcome labels.
    atoms=atoms_tool.make_atoms(anchor_arrays['discovery'],CAT)
    counts=collections.Counter(a.group for a in atoms);parents=collections.defaultdict(collections.Counter)
    for a in atoms:parents[a.group][a.parent]+=1
    pairs={}
    for g,k in [('T','T'),('S','S'),('M','M'),('T','S'),('T','M'),('S','M')]:pairs[g+k]=counts[g]*counts[k] if g!=k else (counts[g]**2-sum(v*v for v in parents[g].values()))//2
    budget=dict(atomCount=len(atoms),atomsBySource=dict(counts),pairCounts=pairs,pairs=sum(pairs.values()),AND3Upper=200*len(atoms),AND4Upper=200*len(atoms),ORUpper=19900,initialUpper=sum(pairs.values())+400*len(atoms)+19900,thresholdSource='A/B W1,W2 original SELL causal features only, no future rows or outcome labels',searches=0)
    budget['batchesAtTwoMillion']=math.ceil(budget['initialUpper']/2000000)
    save('atoms-no-outcome-ranking.json',[dict(id=a.id,name=a.name,parent=a.parent,group=a.group,op=a.op,value=a.value) for a in atoms]);save('search-budget.json',budget)
    def summarize(ops):
        complete=[o for o in ops if o['completeTen']];positive=[o for o in complete if o['fullOpportunity']]
        return dict(events=len(ops),complete=len(complete),truncated=len(ops)-len(complete),higher=len(positive),noHigher=len(complete)-len(positive),higherRate=len(positive)/len(complete) if complete else None,medianMaxGainPct=statistics.median(o['maxGainPct'] for o in complete) if complete else None,medianPositiveMaxGainPct=statistics.median(o['maxGainPct'] for o in positive) if positive else None,medianFirstPeakOffset=statistics.median(o['firstPeakOffset'] for o in positive) if positive else None)
    save('opportunity-summary.json',dict(all=summarize(all_ops),partitions={l:summarize([o for o in all_ops if o['partition']==l]) for l in matrices},cells={s+str(w):summarize([o for o in all_ops if o['sample']==s and o['window']==w]) for s in 'AB' for w in (1,2,3)},exits={r:summarize([o for o in all_ops if o['exitRoute']==r]) for r in ('profit','recovery','both')},retrospectiveOnly=True,strategyPerformanceMeasured=False))
    save('numerical-audit.json',dict(passed=True,checks=dict(audit),maxAbsoluteErrors=dict(errors),marketRows=len(calc)))
    for path,digest in SOURCES.items():assert sha(R/path)==digest,path
    save('source-hashes.json',SOURCES)
    save('summary.json',dict(status='extraction-complete',stage='SD-P02',events=len(all_ops),rows=sum(len(X) for X in matrices.values()),uniqueRows=len(selected),fields=len(CAT),futureS='all NaN; baseline descriptive stored separately',sourcesUnchanged=len(SOURCES),checks=dict(audit),searches=0,strategyReplays=0,next='controls and documentation before completion'))
    print('EXTRACTION_COMPLETE',json.dumps(read(O/'opportunity-summary.json')['all']),flush=True)

if __name__=='__main__':main()
