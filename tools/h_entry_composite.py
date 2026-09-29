#!/usr/bin/env python3
"""HC-D: read-only v33 H-entry trajectory discovery; never strategy replay."""
from __future__ import annotations
import argparse, csv, hashlib, heapq, itertools, json, math, sqlite3, sys, time
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
import numpy as np
import fwd_v20_path_discovery as old

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'exports/h-entry-composite-20260923'
COMMIT = '8d7ad2ef908b32ce7c271baf2404580903b35238'
MARKET = ROOT/'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af'
PATHS = ROOT/'exports/market-data/taiex/research/mkt-pp-p1-taiex-price-path-f712b360c322/market-price-path.csv'
WINDOWS = {1:('browse.store',20170722,20200722),2:('period-20200722.store',20200722,20230722),3:('period-20230722.store',20230722,20260722)}
# Small specified first differences; no lookback grid.
DELTAS = ['t_z125','ma20_diff','ma60_diff','osc_z125','kd_k','v_z125',
          'market_z_125','market_ma_20_diff','market_ma_60_diff','market_osc_z_125',
          's_fit_level','s_fit_trend']

def dump(name,obj):
    p=OUT/name;p.parent.mkdir(parents=True,exist_ok=True)
    tmp=p.with_suffix(p.suffix+'.tmp');tmp.write_text(json.dumps(obj,ensure_ascii=False,indent=2,allow_nan=False)+'\n');tmp.replace(p)
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
def db(p):
    assert p.exists(),p
    wal=Path(str(p)+'-wal');assert not wal.exists() or wal.stat().st_size==0,wal
    c=sqlite3.connect(f'file:{p}?mode=ro',uri=True);c.row_factory=sqlite3.Row
    return c

def reportdir(sample):
    return ROOT/f'exports/backtest-reports/baseline-{sample.lower()}-v33-s45-market-same-day-t3s57-9y-fixed3y-600w-20260918'
def basedir(sample):
    return next((ROOT/'exports/backtest-decision-bases').glob(sample.lower()+'-*-v19'))
def dateof(seconds):
    return int((datetime(2001,1,1,tzinfo=timezone.utc)+timedelta(seconds=seconds,hours=8)).strftime('%Y%m%d'))
def csvmap(p):
    with p.open() as f:return {int(r['date'].replace('-','')):r for r in csv.DictReader(f)}
def bitmask(a):return int.from_bytes(np.packbits(np.asarray(a,dtype=np.uint8),bitorder='little').tobytes(),'little')
def finite(x):return x is not None and math.isfinite(float(x))

def preflight():
    sources={};summary={}
    for sample in 'ABCDE':
        rd=reportdir(sample);bd=basedir(sample)
        for directory in (rd,bd):
            m=json.loads((directory/'manifest.json').read_text())
            assert m['ruleCommit']==COMMIT and m['dataRuleVersion']=='T3/S57'
            assert m['ruleVersion']=='s45-market-same-day-20260915'
            assert m['moneyBaseWan']==600 and m['automaticInvestments']==2
            assert m['through']=='2026/07/22' and m['stockCount']==10
            sources[str((directory/'manifest.json').relative_to(ROOT))]=sha(directory/'manifest.json')
        with db(bd/'decisions.sqlite') as c:
            assert c.execute('pragma quick_check').fetchone()[0]=='ok'
            meta=dict(c.execute('select key,value from metadata'))
            assert meta['ruleCommit']==COMMIT and meta['dataRuleVersion']=='T3/S57'
            assert len(c.execute('select * from windows').fetchall())==3
        summary[sample]={'identity':'passed','effects_read':sample in 'AB'}
        if sample in 'AB':
            for p in [bd/'decisions.sqlite',rd/'browse.store',rd/'period-20200722.store',rd/'period-20230722.store']:
                sources[str(p.relative_to(ROOT))]=sha(p)
    m=json.loads((MARKET/'manifest.json').read_text())
    for name,digest in m['files'].items():
        assert sha(MARKET/name)==digest
        sources[str((MARKET/name).relative_to(ROOT))]=digest
    assert sha(PATHS)==json.loads((reportdir('A')/'manifest.json').read_text())['marketInput']['pricePathSHA256']
    sources[str(PATHS.relative_to(ROOT))]=sha(PATHS)
    dump('sources.json',sources);dump('preflight.json',summary)
    print('preflight: A-E identity and market hashes passed; only AB effects permitted',flush=True)


def catalog():
    rows=[]
    for name,col,family,desc in old.BASE_FEATURE_SPECS:
        rows.append(dict(name=name,source=col,family=family,description=desc,kind='continuous',timing='current official TWSE day; volume not intraday accumulated',warmup='250 prior/current price observations; volume 250 positive TWSE observations',parent=name))
    for name,col,ext,family,desc in old.EXTREME_FLAG_SPECS:
        rows.append(dict(name=name,source=f'{col} == {ext}',family=family,description=desc,kind='boolean',timing='current official day inclusive extrema',warmup='250',parent=family))
    # Keep dimensionless positions, relative differences and duration; absolute
    # market prices/turnover amounts/EMA levels are explicitly excluded.
    with (MARKET/'field-catalog.csv').open() as f:
        for r in csv.DictReader(f):
            name=r['field']
            eligible=('diff' in name or '_z_' in name or name.endswith('_days') or name in ('market_kd_k','market_kd_d','market_kd_j'))
            if not eligible:continue
            rows.append(dict(name=name,source='market-technical.csv:'+name,family=r['category'],description=r['formula_family'],kind='continuous',timing='same calendar day; activity fields need official market input in candidate engine',warmup='250 market observations',parent=name))
    for prefix,src in [('price','ZTPRICEPATHPHASERAW'),('market','market-price-path.csv:phase_raw')]:
        for label,codes in [('peak',(2,3)),('pullback',(4,5)),('bottom',(6,7)),('rebound',(8,9)),('late',(3,5,7,9))]:
            rows.append(dict(name=prefix+'_path_'+label,source=src,family=prefix+'-path',description=str(codes),kind='boolean',timing='current official day',warmup='phase != 0',parent=prefix+'_path'))
    for name,desc in [('s_grade','decision grade; none excluded'),('s_fit_level','decision-time efficiency'),('s_fit_trend','previous completed EMA difference'),('s_roi_trend','previous completed ROI EMA difference'),('s_days_trend','previous completed duration EMA difference')]:
        rows.append(dict(name=name,source='DecisionBase decision_events/strategy_fit_observations',family='S',description=desc,kind='grade' if name=='s_grade' else 'continuous',timing='pre-decision; post-entry states descriptive only',warmup='valid active grade; EMA count >=125 for trend',parent=name))
    for name in DELTAS:
        assert name in [r['name'] for r in rows],name
        rows.append(dict(name='delta_'+name,source=name+' - previous trading observation',family='delta',description='one-day difference',kind='continuous',timing='current minus immediately previous day; both mature',warmup='both finite',parent=name))
    assert len({r['name'] for r in rows})==len(rows)
    return rows


def features(r,prev,event,fit,m,mp,obs_count,vol_count):
    f={};mature=obs_count>=250
    for name,col,family,desc in old.BASE_FEATURE_SPECS:
        ready=mature and (not name.startswith('v_') or vol_count>=250)
        f[name]=r[col] if ready else np.nan
    for name,col,ext,family,desc in old.EXTREME_FLAG_SPECS:
        ready=mature and (not family.startswith('volume') or vol_count>=250)
        f[name]=float(r[col]==r[ext]) if ready else np.nan
    for spec in CAT:
        name=spec['name']
        if spec['source'].startswith('market-technical.csv:'):
            f[name]=float(m[name]) if m and m['price_mature_250']=='true' and all(m.get(x,'true')=='true' for x in ('market_volume_mature_250','market_value_mature_250','market_transaction_mature_250')) else np.nan
    for prefix,phase in [('price',r['ZTPRICEPATHPHASERAW']),('market',int(mp['phase_raw']) if mp else 0)]:
        for label,codes in [('peak',(2,3)),('pullback',(4,5)),('bottom',(6,7)),('rebound',(8,9)),('late',(3,5,7,9))]:
            f[prefix+'_path_'+label]=float(phase in codes) if phase else np.nan
    active=event and event['grade']!=0 and fit and fit['grade_activation_passed'] and fit['is_finite']
    f['s_grade']=event['grade'] if active else np.nan
    f['s_fit_level']=fit['fit_level'] if active else np.nan
    for target,source in [('s_fit_trend','fit_trend'),('s_roi_trend','roi_trend'),('s_days_trend','days_trend')]:
        value=fit[source] if active and fit['fit_observation_count']>=125 else None
        f[target]=value if finite(value) else np.nan
    for name in DELTAS:
        f['delta_'+name]=f[name]-prev.get(name,np.nan) if prev else np.nan
    return f


def cut_round(prices,inventory,start,end,closed):
    """No outcomes/indicators used to locate raw close-based decline and trough."""
    rose=False;decline=None
    for j in range(start+1,end+1):
        if prices[j]<prices[j-1] and not rose:
            return dict(decline=None,trough=None,kind='fell_before_rise',censored=not closed)
        if prices[j]<prices[j-1] and rose and inventory[j]>0:
            decline=j;break
        if prices[j]>prices[j-1]:rose=True
    if decline is None:
        return dict(decline=None,trough=None,kind='rose_exit_before_decline' if rose and closed else 'no_qualified_decline',censored=not closed)
    trough=min(range(decline,end+1),key=lambda j:prices[j])
    boundary=prices[trough]==prices[end]
    return dict(decline=decline,trough=trough,kind='rise_fall',censored=not closed,bottom_boundary=boundary,
                opportunity=closed and not boundary and prices[trough]<prices[start])


def extract(label,windows):
    global CAT
    CAT=catalog();dump('feature-catalog.json',CAT)
    market=csvmap(MARKET/'market-technical.csv');mp=csvmap(PATHS)
    matrix=[];keys=[];rounds=[];checks=Counter();exclusions=Counter()
    for sample in 'AB':
        with db(basedir(sample)/'decisions.sqlite') as c:
            events={};fits={}
            for w in windows:
                for e in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where window_id=? and phase=1',(w,)):
                    k=(w,e['stock_id'],e['trade_date']);assert k not in events;events[k]=dict(e)
                for f in c.execute('select f.*,s.stock_id from strategy_fit_observations f join stocks s using(stock_key) where window_id=?',(w,)):
                    fits[w,f['stock_id'],f['trade_date']]=dict(f)
            # Independently count eligible entry events for row reconstruction.
            expected=sum(e['planned_action']=='H' and e['executed_action']=='BUY' and e['inventory_before']==0 for e in events.values())
        actual=0
        for w in windows:
            filename,startdate,enddate=WINDOWS[w]
            with db(reportdir(sample)/filename) as c:
                assert c.execute('pragma quick_check').fetchone()[0]=='ok'
                stocks=c.execute('select Z_PK,ZSID,ZSNAME,ZTECHNICALSTATEVERSION,ZSIMULATIONSTATEVERSION from ZSTOCK').fetchall()
                for stock in stocks:
                    if stock['ZSID'] not in {k[1] for k in events if k[0]==w}:continue
                    assert stock['ZTECHNICALSTATEVERSION']==3 and stock['ZSIMULATIONSTATEVERSION']==57
                    raw=[dict(r) for r in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(stock['Z_PK'],))]
                    local=[];prev={};vol_count=0
                    for n,r in enumerate(raw):
                        day=dateof(r['ZDATETIME'])
                        vol_count+=int(r['ZVOLUMECLOSE']>0 and r['ZDATASOURCE']=='TWSE')
                        e=events.get((w,stock['ZSID'],day));fit=fits.get((w,stock['ZSID'],day))
                        f=features(r,prev,e,fit,market.get(day),mp.get(day),n+1,vol_count);prev=f
                        if not startdate<=day<=enddate:continue
                        assert r['ZPRICECLOSE']>0
                        local.append((r,day,e,fit,f))
                    # Only dates represented by authoritative decision events.
                    local=[t for t in local if t[2] is not None]
                    base=len(matrix)
                    for r,day,e,fit,f in local:
                        matrix.append([float(f[x['name']]) if finite(f[x['name']]) else np.nan for x in CAT])
                        keys.append(dict(sample=sample,window=w,stock=stock['ZSID'],date=day,close=r['ZPRICECLOSE'],h_score=e['decision_score'],h_threshold=e['decision_threshold'],inventory=e['inventory_before']))
                    prices=[t[0]['ZPRICECLOSE'] for t in local];inv=[t[0]['ZSIMQTYINVENTORY'] for t in local]
                    for i,(r,day,e,fit,f) in enumerate(local):
                        if not(e['planned_action']=='H' and e['executed_action']=='BUY' and e['inventory_before']==0):continue
                        assert r['ZSIMQTYBUY']>0 and r['ZSIMRULEBUY']=='H',(sample,w,stock['ZSID'],day,r['ZSIMRULEBUY'])
                        actual+=1;checks['entry_matches']+=1
                        end=next((j for j in range(i+1,len(local)) if inv[j]==0),len(local)-1)
                        closed=inv[end]==0
                        if closed:assert local[end][0]['ZSIMQTYSELL']>0
                        info=cut_round(prices,inv,i,end,closed)
                        tr=info['trough'];decl=info['decline']
                        rr=dict(id=f'{sample}-W{w}-{stock["ZSID"]}-{day}',sample=sample,window=w,stock=stock['ZSID'],name=stock['ZSNAME'],entry=base+i,end=base+end,entry_date=day,end_date=local[end][1],entry_price=prices[i],closed=closed,
                            decline=None if decl is None else base+decl,trough=None if tr is None else base+tr,kind=info['kind'],censored=info['censored'],bottom_boundary=bool(info.get('bottom_boundary',False)),opportunity=bool(info.get('opportunity',False)),
                            minimum=None if tr is None else prices[tr],min_date=None if tr is None else local[tr][1],grade=e['grade'],entry_h_score=e['decision_score'])
                        rounds.append(rr)
                    checks['stock_windows']+=1
            print(f'extract {label} {sample}/W{w}: rows={len(matrix)} rounds={len(rounds)}',flush=True)
        assert actual==expected,(sample,actual,expected)
    X=np.asarray(matrix,dtype=np.float64)
    np.savez_compressed(OUT/f'{label}.npz',X=X)
    dump(f'{label}-keys.json',keys);dump(f'{label}-rounds.json',rounds)
    dump(f'{label}-summary.json',dict(checks=checks,rows=len(keys),features=X.shape[1],rounds=len(rounds),groups=dict(Counter(f'{r["sample"]}-W{r["window"]}:{r["kind"]}:{r["opportunity"]}:{r["censored"]}' for r in rounds)),missing={x['name']:int(np.isnan(X[:,j]).sum()) for j,x in enumerate(CAT)}))
    return X,keys,rounds


def load(label):
    return np.load(OUT/f'{label}.npz')['X'],json.loads((OUT/f'{label}-keys.json').read_text()),json.loads((OUT/f'{label}-rounds.json').read_text())


# Boolean grammar: each branch is AND of atoms, expression is OR of <=2 branches.
def coarse(v):
    return float(f'{v:.2g}') if v else 0.0

def atom_array(atom,X):
    v=X[:,atom['feature']];ok=np.isfinite(v);op=atom['op']
    if op=='lt':return ok&(v<atom['value']),ok
    if op=='gt':return ok&(v>atom['value']),ok
    if op=='eq':return ok&(v==atom['value']),ok
    return ok&(v>atom['value'][0])&(v<atom['value'][1]),ok

def make_atoms(X,cat):
    atoms=[]
    for j,spec in enumerate(cat):
        v=X[:,j];v=v[np.isfinite(v)]
        if len(v)==0:continue
        defs=[]
        if spec['kind']=='boolean':defs=[('eq',0.0,'boolean'),('eq',1.0,'boolean')]
        elif spec['kind']=='grade':
            defs=[(op,q,'grade_boundary') for q in (-2.5,-1.5,0.5,1.5,2.5) for op in ('lt','gt')]
        else:
            cuts={coarse(float(np.quantile(v,q))):f'q{int(100*q)}' for q in (.25,.5,.75)}
            if np.min(v)<0<np.max(v):cuts[0.0]='natural_zero'
            for cut,origin in sorted(cuts.items()):
                defs.extend((op,cut,origin) for op in ('lt','gt'))
            lo=coarse(float(np.quantile(v,.25)));hi=coarse(float(np.quantile(v,.75)))
            if hi>lo:defs.append(('between',[lo,hi],'q25_q75'))
        seen=set()
        for op,value,origin in defs:
            a=dict(feature=j,name=spec['name'],parent=spec['parent'],op=op,value=value,origin=origin)
            m,valid=atom_array(a,X);key=bitmask(m)
            # Remove constants and exact aliases only, never select by outcomes.
            if key==0 or key==bitmask(valid) or key in seen:continue
            seen.add(key);a['id']=len(atoms);atoms.append(a)
    return atoms

def eval_expr(expr,atoms,X):
    result=np.zeros(len(X),dtype=bool);valid=np.ones(len(X),dtype=bool)
    for branch in expr:
        bm=np.ones(len(X),dtype=bool)
        for aid in branch:
            m,v=atom_array(atoms[aid],X);bm&=m;valid&=v
        result|=bm
    return result&valid,valid

def format_expr(expr,atoms):
    def fmt(a):
        n=a['name'];v=a['value']
        if a['op']=='between':return f'{v[0]:g} < {n} < {v[1]:g}'
        return f'{n} '+{'gt':'>','lt':'<','eq':'=='}[a['op']]+f' {v:g}'
    return ' OR '.join('('+' AND '.join(fmt(atoms[i]) for i in branch)+')' for branch in expr)

def search_observations(X,keys,rounds):
    # Each round has one entry; each completed opportunity gets four broad,
    # equally weighted price-depth references rather than a minimum-day label.
    indices=[r['entry'] for r in rounds];meta=[dict(round=i,role='entry') for i in range(len(rounds))]
    for i,r in enumerate(rounds):
        if not r['opportunity'] or r['censored']:continue
        entry=r['entry_price'];low=r['minimum']
        for depth in (.25,.5,.75,1.0):
            target=entry-depth*(entry-low)
            j=min(range(r['decline'],r['end']+1),key=lambda j:(abs(keys[j]['close']-target),j))
            indices.append(j);meta.append(dict(round=i,role='reference',depth=depth))
    return X[indices],meta,indices

class Screener:
    def __init__(self,meta,rounds):
        self.entry=bitmask([x['role']=='entry' for x in meta])
        self.low=bitmask([x['role']=='reference' for x in meta])
        self.groups=[]
        for w in (1,2):
            pos=bitmask([x['role']=='entry' and rounds[x['round']]['window']==w and rounds[x['round']]['opportunity'] for x in meta])
            neg=bitmask([x['role']=='entry' and rounds[x['round']]['window']==w and rounds[x['round']]['closed'] and not rounds[x['round']].get('bottom_boundary',False) and not rounds[x['round']]['opportunity'] for x in meta])
            self.groups.append((pos,neg))
    def score(self,m,valid):
        lifts=[];n=0
        for pos,neg in self.groups:
            p=(pos&valid).bit_count();q=(neg&valid).bit_count()
            hit=(m&pos).bit_count();n+=hit
            if p==0 or q==0:return None
            lifts.append(hit/p-(m&neg).bit_count()/q)
        if n<4:return None  # Ranking capacity only; all rules are still counted.
        den=(self.low&valid).bit_count()
        release=((self.low&valid&~m).bit_count()/den) if den else 0
        # Lexicographic discovery ranking, not a trading-performance score.
        return (round(min(lifts),2),round(release,2),round(sum(lifts)/2,2),n)


def choose_beam(records,atoms,width=200):
    # Preserve source/feature-family diversity, not only tiny cut variants.
    ranked=sorted(records,key=lambda x:x['score'],reverse=True)
    out=[];seen=set();familycounts=Counter()
    for r in ranked:
        signature=tuple(sorted({atoms[a]['parent'] for branch in r['expr'] for a in branch}))
        if familycounts[signature]>=2 or r['mask'] in seen:continue
        seen.add(r['mask']);familycounts[signature]+=1;out.append(r)
        if len(out)>=width:break
    return out


def run_search():
    assert not (OUT/'frozen-candidates.json').exists(),'Do not rerun a frozen search'
    X,keys,rounds=load('discovery');cat=json.loads((OUT/'feature-catalog.json').read_text())
    # Thresholds use unique discovery stock-dates, never weighted by repeated low labels.
    atoms=make_atoms(X,cat);SX,meta,indices=search_observations(X,keys,rounds)
    am=[];av=[]
    for a in atoms:
        m,v=atom_array(a,SX);am.append(bitmask(m));av.append(bitmask(v))
    pair_count=sum(atoms[i]['parent']!=atoms[j]['parent'] for i in range(len(atoms)) for j in range(i+1,len(atoms)))
    estimate=pair_count+2*200*len(atoms)+200*199//2
    print(f'search preflight: {len(atoms)} atoms; pair={pair_count}; upper estimate={estimate}',flush=True)
    assert estimate<=2000000,('search capacity exceeded',estimate)
    dump('search-spec.json',dict(atoms=len(atoms),featureCount=len(cat),pairs=pair_count,estimatedEvaluations=estimate,
        threshold_source='unique A/B W1,W2 dates only; quartiles rounded 2 significant digits plus zero; no outcome tuning',
        ranking='lexicographic: minimum W1/W2 entry opportunity enrichment; low-reference release; mean enrichment; opportunity coverage',
        opportunity='completed rise-fall round whose subsequent minimum is below entry, no minimum depth cutoff',
        reference='four equal price-depth reference observations at .25/.5/.75/1 of entry-to-min drop; ordinal search proxy only; full daily sequence checked later',
        censored='excluded from opportunity/other labels, retained in detailed review',
        stock_checks='leave-stock-out threshold sensitivity after structure selection; not independent validation',
        unseen_within_this_run='W3 labels/effects not yet extracted',maxConditions=2000000))
    dump('atoms.json',atoms);dump('search-observation-map.json',[dict(**x,row=indices[i]) for i,x in enumerate(meta)])
    screen=Screener(meta,rounds);count=0;serial=0;t0=time.monotonic();stats={};reservoir=[]
    def consider(expr,m,v,heap):
        nonlocal count,serial
        count+=1;assert count<=2000000
        score=screen.score(m,v)
        if score is None:return
        r=dict(expr=[list(b) for b in expr],mask=m,valid=v,score=score)
        serial+=1;item=(score,serial,r)
        if len(heap)<10000:heapq.heappush(heap,item)
        elif score>heap[0][0]:heapq.heapreplace(heap,item)
    heap=[]
    for i,a in enumerate(atoms):
        for j in range(i+1,len(atoms)):
            if a['parent']==atoms[j]['parent']:continue
            consider(((i,j),),am[i]&am[j],av[i]&av[j],heap)
        if i and i%100==0:print(f'pairs {i}/{len(atoms)} evaluated={count} elapsed={time.monotonic()-t0:.1f}s',flush=True)
    beam=choose_beam([r for _,_,r in heap],atoms);reservoir+=beam;stats['pairs']=count
    for depth in (3,4):
        heap=[];seen_expr=set()
        for r in beam:
            branch=r['expr'][0];parents={atoms[a]['parent'] for a in branch}
            for a in atoms:
                if a['parent'] in parents:continue
                expr=tuple(sorted(branch+[a['id']]))
                if expr in seen_expr:continue
                seen_expr.add(expr)
                consider((expr,),r['mask']&am[a['id']],r['valid']&av[a['id']],heap)
        beam=choose_beam([r for _,_,r in heap],atoms);reservoir+=beam;stats[f'through_{depth}']=count
        print(f'depth {depth} evaluated={count} retained={len(beam)}',flush=True)
    # OR branches drawn from all retained shapes, width bounded at 200.
    branches=choose_beam(reservoir,atoms);heap=[]
    for i,r in enumerate(branches):
        for q in branches[i+1:]:
            parents={atoms[a]['parent'] for b in r['expr']+q['expr'] for a in b}
            if len(parents)>4:continue
            v=r['valid']&q['valid'];m=(r['mask']|q['mask'])&v
            if m in (r['mask'],q['mask']):continue
            consider(r['expr']+q['expr'],m,v,heap)
    ors=choose_beam([r for _,_,r in heap],atoms);reservoir+=ors
    # Freeze broad shortlist before loading W3. All are hypotheses, not performance claims.
    chosen=[]
    for r in sorted(reservoir,key=lambda x:x['score'],reverse=True):
        entrymask=r['mask']&screen.entry
        if any((entrymask&(q['mask']&screen.entry)).bit_count()/max(1,(entrymask|(q['mask']&screen.entry)).bit_count())>=.8 for q in chosen):continue
        chosen.append(r)
        if len(chosen)==6:break
    payload=[]
    for i,r in enumerate(chosen,1):
        fields=sorted({atoms[a]['name'] for b in r['expr'] for a in b})
        payload.append(dict(id=f'HC-D{i:02}',expr=r['expr'],expression=format_expr(r['expr'],atoms),fields=fields,discovery_rank=list(r['score']),status='frozen descriptive hypothesis; not replayed'))
    dump('frozen-candidates.json',dict(frozenBeforeLaterExtraction=True,discoveryInputs={x:sha(OUT/x) for x in ['discovery.npz','discovery-rounds.json','atoms.json','search-spec.json']},candidates=payload))
    # Limited audit ledger of retained nodes; no costly copy of every bit vector.
    dump('search-retained.json',[dict(expr=r['expr'],expression=format_expr(r['expr'],atoms),rank=list(r['score'])) for r in reservoir])
    stats.update(total=count,elapsedSeconds=time.monotonic()-t0,candidates=len(payload),retained=len(reservoir))
    dump('search-summary.json',stats);print(json.dumps(stats),flush=True)


def review(label):
    X,keys,rounds=load(label);atoms=json.loads((OUT/'atoms.json').read_text());frozen=json.loads((OUT/'frozen-candidates.json').read_text())
    all_results=[]
    for candidate in frozen['candidates']:
        signal,valid=eval_expr(candidate['expr'],atoms,X);detail=[]
        for r in rounds:
            b,e=r['entry'],r['end'];hit=bool(signal[b]);rr=dict(r)
            rr.update(entryHit=hit,entryValid=bool(valid[b]))
            if hit:
                # Counterfactual qualification after the first divergence is unknown:
                # this is raw condition release, not a new simulated trade.
                release=next((j for j in range(b+1,e+1) if not signal[j]),None)
                rr.update(first_release_date=keys[release]['date'] if release is not None else None,
                    first_release_price=keys[release]['close'] if release is not None else None,
                    release_missing=bool(not valid[release]) if release is not None else None,
                    first_release_change_pct=100*(keys[release]['close']/r['entry_price']-1) if release is not None else None,
                    first_release_before_decline=bool(release is not None and r['decline'] is not None and release<r['decline']))
                if r['decline'] is not None:
                    ids=np.arange(r['decline'],e+1);cl=np.array([keys[j]['close'] for j in ids]);gap=r['entry_price']-r['minimum']
                    if gap>0:
                        weight=np.clip((r['entry_price']-cl)/gap,0,1);den=weight[valid[ids]].sum()
                        rr['low_price_weighted_release']=float((weight*(~signal[ids])*valid[ids]).sum()/den) if den else None
                    rr['trough_released']=bool(not signal[r['trough']]) if valid[r['trough']] else None
            detail.append(rr)
        groups={}
        for group in sorted({f'{r["sample"]}-W{r["window"]}' for r in rounds}):
            rs=[r for r in detail if f'{r["sample"]}-W{r["window"]}'==group];hits=[r for r in rs if r['entryHit']]
            opp=[r for r in rs if r['opportunity']];controls=[r for r in rs if r['closed'] and not r.get('bottom_boundary',False) and not r['opportunity']]
            changes=[r['first_release_change_pct'] for r in hits if r.get('first_release_change_pct') is not None]
            l=[r['low_price_weighted_release'] for r in hits if r.get('low_price_weighted_release') is not None]
            groups[group]=dict(rounds=len(rs),entry_hits=len(hits),stocks=len({r['stock'] for r in hits}),opportunities=len(opp),opportunity_hits=sum(r['entryHit'] for r in opp),other_closed=len(controls),other_hits=sum(r['entryHit'] for r in controls),
                opportunity_enrichment=(sum(r['entryHit'] for r in opp)/len(opp)-sum(r['entryHit'] for r in controls)/len(controls)) if opp and controls else None,
                first_release_cheaper=sum(x<0 for x in changes),first_release_dearer=sum(x>0 for x in changes),first_release_equal=sum(x==0 for x in changes),no_release=sum(r.get('first_release_date') is None for r in hits),missing_releases=sum(r.get('release_missing') is True for r in hits),
                median_release_change_pct=float(np.median(changes)) if changes else None,mean_low_price_release=float(np.mean(l)) if l else None)
        # Every atom deletion: descriptive contribution only; no additional candidate.
        ablations=[]
        for aid in sorted({a for b in candidate['expr'] for a in b}):
            expr=[[a for a in b if a!=aid] for b in candidate['expr']]
            sig,_=eval_expr(expr,atoms,X)
            ablations.append(dict(removed_atom=aid,expression=format_expr(expr,atoms),entry_hits=sum(bool(sig[r['entry']]) for r in rounds)))
        dump(f'{label}-{candidate["id"]}-cases.json',detail)
        result=dict(id=candidate['id'],expression=candidate['expression'],groups=groups,ablations=ablations)
        all_results.append(result)
    dump(f'{label}-review.json',all_results)
    print(json.dumps(all_results,ensure_ascii=False)[:12000],flush=True)

def main():
    p=argparse.ArgumentParser();p.add_argument('stage',choices=['preflight','extract','later-extract','search','review','later-review']);a=p.parse_args()
    if a.stage=='preflight':preflight()
    elif a.stage=='extract':extract('discovery',[1,2])
    elif a.stage=='search':run_search()
    elif a.stage=='review':review('discovery')
    elif a.stage=='later-review':review('later')
    else:
        assert (OUT/'frozen-candidates.json').exists(),'Freeze candidates before W3 effects'
        extract('later',[3])
if __name__=='__main__':main()
