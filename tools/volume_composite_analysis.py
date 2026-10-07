#!/usr/bin/env python3
"""VCX bounded descriptive cases and frozen candidate screening; no replay."""
import collections as C,json,math,statistics as S,sys,time
import volume_composite as v
O=v.O
ACTIONS={'H_early':'hEarly','L_early':'lEarly','H_delay':'hDelay','L_delay':'lDelay','S_early':'sEarly','S_delay':'sDelay','LC_delay':'lcDelay','R_delay':'recoveryDelay','A_early':'aEarly','A_delay':'aDelay'}
VOL=['svz','sv20','sv60','svdays','dsvz','mvz','mv20','mv60','dmvz','valuez','transz']
def med(xs):return S.median(xs) if xs else None
def mean(xs):return S.mean(xs) if xs else None
def bg(name,f):
    if name=='all':return True
    if name=='peak_rising':return f['phase'] in (2,3) and f['d20']>0
    if name=='rebound':return f['phase'] in (8,9) and f['d20']>0
    if name=='pullback':return f['phase'] in (4,5) and f['d20']<0
    if name.startswith('phase_'):return f['phase'] in {'flat':(1,),'peak':(2,3),'pullback':(4,5),'bottom':(6,7),'rebound':(8,9)}[name[6:]]
    raise ValueError(name)
def vol(name,f):
    tests={'sv_low':f['svz']<0,'mv_low':f['mvz']<0,'both_low':f['svz']<0 and f['mvz']<0,'sv_high':f['svz']>1,'mv_high':f['mvz']>1,'both_high':f['svz']>1 and f['mvz']>1,'sv_recover':f['svz']<0 and f['dsvz']>0,'sv20_low':f['sv20']<0,'sv20_high':f['sv20']>0,'mv20_low':f['mv20']<0,'mv20_high':f['mv20']>0,'mv_recover':f['mvz']<0 and f['dmvz']>0,'sv_decline':f['dsvz']<0,'value_high':f['valuez']>1,'trans_high':f['transz']>1}
    return tests[name]
def match(h,r,variant='full'):
    return not r['quality'] and (variant=='volumeOnly' or bg(h['background'],r['features'])) and (variant=='background' or vol(h['volume'],r['features']))
def sign(action):return -1 if action in ('H_delay','L_delay','A_delay','S_early') else 1
def forward(rows,i,h):
    target=rows[i]['index']+h
    for r in rows[i+1:i+h+2]:
        if r['index']==target:return r
        if r['index']>target:return None
    return None
def anchor_key(action,r):
    if action.startswith(('H_','L_')):return ('flat',r['segment'])
    if action.startswith('A_'):return ('held',r['round'],r['features']['invests'])
    return ('held',r['round'])
def future_origin(action,rows,i):
    r=rows[i]
    if 'early' not in action:return None
    for x in rows[i+1:]:
        if action.startswith(('H_','L_')):
            if x['segment']!=r['segment'] or not x['flat']:return None
            if x['qtyBuy']>0:return x
        else:
            if x['round']!=r['round'] or not x['held']:return None
            if action=='S_early' and x['qtySell']>0:return x
            if action=='A_early':
                if x['investAdded']==1:return x
                if x['qtySell']>0:return None
    return None
def profile():
    assert not (O/'case-profile.json').exists()
    bins=C.defaultdict(lambda:{'positive':C.defaultdict(list),'negative':C.defaultdict(list),'neutral':0,'positiveExamples':[],'negativeExamples':[]})
    counts=C.Counter()
    for path in sorted((O/'units').glob('*.json')):
        u=v.read(path)
        if u['window']==3:continue
        rows=u['rows']
        for action,flag in ACTIONS.items():
            seen=set()
            for i,r in enumerate(rows):
                if not r.get(flag) or r['quality']:continue
                key=anchor_key(action,r)
                if key in seen:continue
                seen.add(key);target=future_origin(action,rows,i) if 'early' in action else forward(rows,i,3)
                if target is None:counts[action+':unknown']+=1;continue
                if 'early' in action and target['index']-r['index']>9:counts[action+':outside9']+=1;continue
                effect=sign(action)*100*(target['price']/r['price']-1)
                # early sell compares current against later exit (positive = current higher).
                ph=next(k for k,ps in {'flat':(1,),'peak':(2,3),'pullback':(4,5),'bottom':(6,7),'rebound':(8,9)}.items() if r['features']['phase'] in ps)
                for b in ('all','phase_'+ph):
                    group=bins[action+'|'+b];side='positive' if effect>1 else 'negative' if effect< -1 else None
                    if side:
                        for f in VOL:group[side][f].append(r['features'][f])
                        ex=dict(unit=u['id'],date=r['date'],target=target['date'],priceDeltaPct=effect,features={k:r['features'][k] for k in VOL+['phase','grade','d20','roi','age','invests']})
                        if len(group[side+'Examples'])<3:group[side+'Examples'].append(ex)
                    else:group['neutral']+=1
                counts[action+':labelled']+=1
        v.progress('case-profile',unit=u['id'])
    out={}
    for k,g in bins.items():
        stats={f:dict(positiveN=len(g['positive'][f]),negativeN=len(g['negative'][f]),positiveMedian=med(g['positive'][f]),negativeMedian=med(g['negative'][f])) for f in VOL}
        out[k]=dict(stats=stats,neutral=g['neutral'],positiveExamples=g['positiveExamples'],negativeExamples=g['negativeExamples'])
    v.save('case-profile.json',dict(discoveryWindows=[1,2],allSamplesPreviouslySeen=True,method='first eligible baseline anchor per flat segment / holding round / investment stage; early comparisons within9 sessions; delay exact3-session price; +/-1% descriptive labels only',counts=dict(counts),profiles=out))
    v.finish('case-profile',profiles=len(out),counts=dict(counts))

def stats(records):
    xs=[r['effect'] for r in records if r['effect'] is not None]
    dates=C.defaultdict(list)
    for r in records:
        if r['effect'] is not None:dates[r['date']].append(r['effect'])
    date_means=[mean(x) for x in dates.values()]
    positive=[r for r in records if r['effect'] is not None and r['effect']>1]
    negative=[r for r in records if r['effect'] is not None and r['effect']< -1]
    return dict(anchors=len(records),comparable=len(xs),unknown=len(records)-len(xs),positive=sum(x>1e-9 for x in xs),negative=sum(x< -1e-9 for x in xs),over1=len(positive),belowMinus1=len(negative),meanPct=mean(xs),medianPct=med(xs),worstPct=min(xs,default=None),bestPct=max(xs,default=None),marketDates=len(dates),dateWeightedMeanPct=mean(date_means),positiveStocks=len(set(r['stock'] for r in positive)),positiveDates=len(set(r['date'] for r in positive)),negativeStocks=len(set(r['stock'] for r in negative)),outsideEvent=sum(not r['withinOriginalEventHorizon'] for r in records),unreleased=sum(r.get('unreleased',False) for r in records),routeUnknown=sum(r.get('routeUnknown',False) for r in records))
def record(h,u,rows,i,variant):
    r=rows[i];action=h['action'];horizon=h['horizon'];target=None;reason=None
    within=False;unreleased=False;origin=None
    if 'early' in action:
        origin=future_origin(action,rows,i)
        within=origin is not None and origin['index']-r['index']<=horizon
        target=origin if within else forward(rows,i,horizon)
        reason='originalSameSegmentOrRoundAction' if within else 'fixedHorizonPriceOnly'
    else:
        for x in rows[i+1:]:
            distance=x['index']-r['index']
            if distance>20:break
            # Only exogenous price/volume predicate can diagnose release. Baseline
            # future holdings, Grade, cash and normal action are deliberately ignored.
            if not match(h,x,variant):target=x;reason='exogenousPredicateReleased';break
        unreleased=target is None
        if target is None:target=forward(rows,i,20);reason='20SessionUnreleasedDiagnostic'
        within=True
    effect=sign(action)*100*(target['price']/r['price']-1) if target else None
    return dict(unit=u['id'],sample=u['sample'],window=u['window'],stock=u['stock'],name=u['name'],date=r['date'],marketVolumeDate=r['marketVolumeDate'],stockVolumeDate=r['stockVolumeDate'],round=r['round'],segment=r['segment'],price=r['price'],grade=r['features']['grade'],roi=r['features']['roi'],holdingDays=r['features']['age'],invests=r['features']['invests'],balance=r['features']['balance'],entryRule=r['entryRule'],sellCategory=r.get('sellCategory'),originalActionDate=origin['date'] if origin else None,withinOriginalEventHorizon=within,targetDate=target['date'] if target else None,targetPrice=target['price'] if target else None,lag=target['index']-r['index'] if target else None,effect=effect,label=reason,unreleased=unreleased,routeUnknown=action=='H_delay' and not r.get('lFallbackProvenAbsent',False),sameQuantity=(target['qtyBefore']==r['qtyBefore']) if target and action=='S_early' and within else None,features=r['features'],existingVolumeVotes={p:{k:x for k,x in vs.items() if k in ('H-P04','H-N10','L-P06','S-N05')} for p,vs in r['votes'].items()},afterDivergenceCandidateStateUsed=False)
def evaluate():
    hs=v.read(O/'theory-frozen.json')['hypotheses']+v.read(O/'case-frozen.json')['hypotheses'];assert len(hs)<=36
    accum={h['id']:{variant:dict(records=[],firsts=[],counters=C.Counter()) for variant in ('full','background','volumeOnly')} for h in hs}
    for path in sorted((O/'units').glob('*.json')):
        u=v.read(path);rows=u['rows']
        for h in hs:
            for variant,a in accum[h['id']].items():
                seen=set();first=True
                for i,r in enumerate(rows):
                    if not r.get(ACTIONS[h['action']]):continue
                    a['counters']['applicableDays']+=1
                    if r['quality']:a['counters']['qualityExcludedDays']+=1;continue
                    if not match(h,r,variant):continue
                    a['counters']['triggerDays']+=1
                    k=anchor_key(h['action'],r)
                    if k in seen:continue
                    seen.add(k);rec=record(h,u,rows,i,variant);a['records'].append(rec)
                    if first:a['firsts'].append(rec);first=False
        v.progress('evaluate',unit=u['id'])
    summaries=[]
    for h in hs:
        out=dict(hypothesis=h,variants={})
        for variant,a in accum[h['id']].items():
            splits={}
            for scope,records in [('baselineAnchors',a['records']),('firstPerStockWindow',a['firsts'])]:
                splits[scope]={k:stats([r for r in records if r['window'] in ws]) for k,ws in [('W12',(1,2)),('W3',(3,)),('all',(1,2,3))]}
                splits[scope]['bySample']={s:stats([r for r in records if r['sample']==s]) for s in 'ABCDE'}
                splits[scope]['byWindow']={str(w):stats([r for r in records if r['window']==w]) for w in (1,2,3)}
            out['variants'][variant]=dict(counters=dict(a['counters']),summary=splits,records=a['records'],firsts=a['firsts'])
        full=out['variants']['full'];back=out['variants']['background']
        fkeys={(r['unit'],r['date']) for r in full['firsts']};bkeys={(r['unit'],r['date']) for r in back['firsts']}
        out['firstActionSetDigest']=__import__('hashlib').sha256(json.dumps(sorted(fkeys)).encode()).hexdigest()
        out['volumeChangedFirstActions']=dict(addedOrDelayed=len(fkeys-bkeys),removedOrDelayed=len(bkeys-fkeys),same=len(fkeys&bkeys))
        # Matched background triggers with and without volume; this is descriptive,
        # not a randomized causal estimate and not an incremental profit result.
        out['backgroundAnchorVolumePresent']=stats([r for r in back['records'] if vol(h['volume'],r['features'])])
        out['backgroundAnchorVolumeAbsent']=stats([r for r in back['records'] if not vol(h['volume'],r['features'])])
        v.save('cards/'+h['id']+'.json',out)
        summaries.append(dict(id=h['id'],hypothesis=h,full=full['summary'],background=back['summary'],volumeOnly=out['variants']['volumeOnly']['summary'],counters=full['counters'],volumeChangedFirstActions=out['volumeChangedFirstActions'],firstActionSetDigest=out['firstActionSetDigest']))
    v.save('screening-summary.json',summaries);v.finish('evaluation',hypotheses=len(hs))
if __name__=='__main__':
    try:
        {'profile':profile,'evaluate':evaluate}[sys.argv[1]]()
    except Exception as e:
        v.save('failure-analysis-'+str(int(time.time()))+'.json',dict(stage=sys.argv[1:],error=repr(e),resources=v.usage()));raise
