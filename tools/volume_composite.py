#!/usr/bin/env python3
"""VCX P01-P04: bounded offline observations, not a strategy replay."""
import os
for _k in ('OMP_NUM_THREADS','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS','VECLIB_MAXIMUM_THREADS','NUMEXPR_NUM_THREADS'):
    os.environ[_k]='1'
import ast,bisect,collections as C,csv,datetime as D,hashlib,json,math,resource,sqlite3,subprocess,sys,time,types
from pathlib import Path
R=Path(__file__).resolve().parents[1]; O=R/'exports/vcx-p01-p04-20261005'
RULE='7ba8447fbf207484ab305cad0c6beca216da8c93'; STRATEGY='s49-sell-delay-f03-r1-20261001'
START=time.monotonic(); CPU=time.process_time(); HASH={}; NAN=float('nan')
resource.setrlimit(resource.RLIMIT_CPU,(3600,3600))
def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()
def source(p):
    p=Path(p); HASH[str(p.relative_to(R))]=sha(p); return p
def read(p):return json.loads(source(p).read_text())
def save(n,x):
    p=O/n;p.parent.mkdir(parents=True,exist_ok=True);t=p.with_suffix(p.suffix+'.tmp')
    t.write_text(json.dumps(x,ensure_ascii=False,allow_nan=False,separators=(',',':'))+'\n');t.replace(p)
def usage():
    return dict(wallSeconds=time.monotonic()-START,cpuSeconds=time.process_time()-CPU,peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,allocatedBytes=sum(p.stat().st_blocks*512 for p in O.rglob('*') if p.is_file()))
def guard():
    u=usage();prior=sum(json.loads(p.read_text())['cpuSeconds'] for p in O.glob('usage-*.json'))
    assert u['cpuSeconds']+prior<3600 and u['peakRSSBytes']<1073741824 and u['allocatedBytes']<1073741824,u
    return u
def progress(stage,**kw):
    save('status.json',dict(stage=stage,**kw,resources=guard()));print(stage,kw,flush=True)
def finish(stage,**kw):
    save('usage-'+stage+'.json',guard());save(stage+'-complete.json',dict(**kw,strategyReplay=False));progress(stage+'-complete',**kw)
def db(p):
    source(p)
    for s in ('-wal','-shm'):
        q=Path(str(p)+s)
        if q.exists():
            source(q)
            if s=='-wal':assert q.stat().st_size==0,q
    c=sqlite3.connect(p.as_uri()+'?mode=ro&immutable=1',uri=True);c.row_factory=sqlite3.Row
    assert c.execute('pragma quick_check').fetchone()[0]=='ok';return c
def day(x):return int((D.datetime(2001,1,1)+D.timedelta(seconds=x,hours=8)).strftime('%Y%m%d'))
def eq(a,b):assert math.isclose(a,b,rel_tol=1e-10,abs_tol=1e-6),(a,b)
def finite(x):return x is not None and math.isfinite(x)
def csvmap(p):
    with source(p).open() as f:return {int(x['date'].replace('-','')):x for x in csv.DictReader(f)}
def load_audited_functions():
    # Reuse only inspected pure functions, not old module entry points/imports.
    paths={'tools/h_entry_composite_p02.py':['phase_next','fit_update','avdays','ownstate','years','level_of'], 'tools/loss_exit_p01.py':['fees','rnd','gates']}
    env=dict(math=math,finite=finite,NAN=NAN,h=types.SimpleNamespace(datetime=D.datetime,dateof=day))
    for path,names in paths.items():
        tree=ast.parse(source(R/path).read_text());nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in names]
        assert len(nodes)==len(names)
        exec(compile(ast.Module(body=nodes,type_ignores=[]),path,'exec'),env)
        env['prior']=types.SimpleNamespace(**{k:env[k] for k in paths['tools/h_entry_composite_p02.py']})
    return env['gates'],env
def preflight():
    assert not (O/'extraction-complete.json').exists()
    assert subprocess.check_output(['git','rev-parse',RULE+'^{commit}'],cwd=R,text=True).strip()==RULE
    source(Path(__file__));source(O/'theory-frozen.json');source(O/'protocol.json')
    differences={}
    for n in ('technical.swift','RollingContext.swift','dataModel.swift','InternalBacktestDecisionBase.swift','SellDelayF01Rule.swift','SellDelayF03Rule.swift','HEntryDelayRule.swift','HEntryIncrementalDelayRule.swift','PullbackProfitSellRule.swift'):
        p=source(R/'simStock3'/n);frozen=subprocess.check_output(['git','show',RULE+':simStock3/'+n],cwd=R)
        if p.read_bytes()!=frozen:
            assert n=='technical.swift'
            # Published 10/04 download/cache changes precede volume/simulation code.
            anchor=b'    private func tUpdate('
            assert anchor in frozen and p.read_bytes().split(anchor,1)[1]==frozen.split(anchor,1)[1]
            q=O/'rule-source'/n;q.parent.mkdir(exist_ok=True);q.write_bytes(frozen)
            differences[n]=dict(current=sha(p),frozen=sha(q),verified='tUpdate, vUpdate and following simulation implementation byte identical')
    save('source-compatibility.json',differences)
    inventory={};common=dict(ruleCommit=RULE,dataRuleVersion='T3/S61',ruleVersion=STRATEGY,through='2026/07/22',moneyBaseWan=600,automaticInvestments=2)
    for s in 'ABCDE':
        bp=list(R.glob('exports/backtest-decision-bases/'+s.lower()+'-*-s49-*-v23'));rp=list(R.glob('exports/backtest-reports/baseline-'+s.lower()+'-v37-*-fixed3y-*'))
        assert len(bp)==len(rp)==1;bp,rp=bp[0],rp[0]
        for folder in (bp,rp):
            m=read(folder/'manifest.json')
            for k,v in dict(common,sampleID=s).items():assert m[k]==v,(folder,k,m[k])
            marker=source(folder/'.complete').read_text().strip();assert marker==m.get('runID',m.get('decisionBaseID'))
        assert m['marketInput']['marketTechnicalVersion']=='6'
        base=read(rp/'baseline.json');source(rp/'periods.csv')
        with db(bp/'decisions.sqlite') as c:
            meta=dict(c.execute('select * from metadata'))
            for k in ('ruleCommit','dataRuleVersion','ruleVersion','through','sampleID'):assert meta[k]==dict(common,sampleID=s)[k]
            assert meta['formatVersion']=='6'
            count=c.execute('select count(*) from decision_events where phase=1').fetchone()[0]
        inventory[s]=dict(report=str(rp.relative_to(R)),decisionBase=str(bp.relative_to(R)),days=count)
    mt=R/'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af';m=read(mt/'manifest.json')
    for name,digest in m['files'].items():assert sha(source(mt/name))==digest
    assert source(mt/'.complete').read_text().strip()==m['snapshot_id']
    save('inventory.json',inventory);save('p01-source-hashes.json',HASH)
    return inventory,mt
def l_upper(r,grade,mmdd):
    # Conservative L score upper bound when H hid the L evaluation; unknown gates
    # can only reduce it. An upper bound below 5 proves no same-day L fallback.
    s=int(r['ZTKDJ']<-1 or r['ZTKDK']<9)+int(r['ZTKDJ']<-7)
    s+=int(r['ZTKDKZ125']<-.9 and r['ZTKDKZ250']<-.9)+int(r['ZTKDDZ125']<-.9 and r['ZTKDDZ250']<-.9)
    s+=int(r['ZTOSCZ125']<-.9 and r['ZTOSCZ250']<-.9)+int(r['ZVZ125']<(-.2 if grade<=-1 else .3))
    s+=int(r['ZTMA60DIFFZ125']>-.5 and grade>=0)
    s+=int(r['ZTHIGHDIFFZ125']<(-1.5 if grade<=-1 else -1.2 if grade>=2 else -1.35))
    s+=int(grade>=-1 and (r['ZTMA60DIFF']<-30 or r['ZTMA20DIFF']<-30))
    s+=int(grade in (-1,1))+int(grade==3)+int(r['ZTPRICEPATHPHASERAW']==9)
    s+=int(821<=mmdd<=831 and grade<=-1)+int(801<=mmdd<=831)
    return s
def extract(limit=None):
    inv,mt=preflight();market=csvmap(mt/'market-technical.csv');daily=csvmap(mt/'market-daily.csv')
    paths=csvmap(R/'exports/market-data/taiex/research/mkt-pp-p1-taiex-price-path-f712b360c322/market-price-path.csv')
    days=sorted(market);mi={d:i for i,d in enumerate(days)};ms=(market,daily,paths)
    gates,env=load_audited_functions();total=C.Counter();units=[]
    for sample in 'ABCDE':
        bp=R/inv[sample]['decisionBase'];rp=R/inv[sample]['report']
        with db(bp/'decisions.sqlite') as c:
            ev={}
            for row in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase in (1,2,3,4)'):
                ev.setdefault((row['window_id'],row['stock_id'],row['trade_date']),{})[row['phase']]=dict(row)
            fits={(r['window_id'],r['stock_id'],r['trade_date']):dict(r) for r in c.execute('select f.*,s.stock_id from strategy_fit_observations f join stocks s using(stock_key)')}
            votes=C.defaultdict(dict);gs=C.defaultdict(set)
            for eid,rid,v in c.execute('select event_id,rule_id,contribution from event_votes join rules using(rule_key)'):votes[eid][rid]=v
            for eid,rid in c.execute('select event_id,rule_id from event_gates join rules using(rule_key)'):gs[eid].add(rid)
        for w,fn in enumerate(('browse.store','period-20200722.store','period-20230722.store'),1):
            gates.start=(20170722,20200722,20230722)[w-1]
            with db(rp/fn) as c:
                stocks=list(c.execute('select * from ZSTOCK'));assert len(stocks)==10
                for st in stocks:
                    assert st['ZTECHNICALSTATEVERSION']==3 and st['ZSIMULATIONSTATEVERSION']==61 and st['ZTECHNICALDIRTYFROM'] is None and st['ZSIMULATIONDIRTYFROM'] is None
                    uid=f'{sample}-{w}-{st["ZSID"]}'
                    ea=read(R/'exports/entry-advance-20261003/units'/f'{uid}.json');aa=read(R/'exports/add-advance-20261003/units'/f'{uid}.json')
                    for old in (ea,aa):
                        assert old['identity']['store']==HASH[str((rp/fn).relative_to(R))] and old['identity']['base']==HASH[str((bp/'decisions.sqlite').relative_to(R))]
                    em={x['date']:x for x in ea['rows']};am={x['date']:x for x in aa['rows']}
                    raw=[dict(x) for x in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],))]
                    rows=[];uc=C.Counter();roundid=0;gap=None;flatseg=0;wasflat=False
                    dates=[day(r['ZDATETIME']) for r in raw];assert dates==sorted(set(dates))
                    for n,r in enumerate(raw):
                        d=dates[n];es=ev.get((w,st['ZSID'],d));prev=raw[n-1] if n else None
                        if es:
                            assert n and 1 in es and d in market and d in daily and d in paths
                            h=es[1];grade=h['grade'];flat=h['inventory_before']==0;held=not flat
                            if flat and not wasflat:flatseg+=1
                            wasflat=flat
                            if flat and r['ZSIMQTYBUY']>0:roundid+=1
                            assert r['ZDATASOURCE']=='TWSE' and not r['ZSIMREVERSED'] and not r['ZSIMINVESTBYUSER']
                            for e in es.values():eq(e['decision_score'],sum(votes[e['event_id']].values()));eq(e['inventory_before'],prev['ZSIMQTYINVENTORY']);uc['eventVotePrestateChecks']+=1
                            m=market[d];md=days[mi[d]-1];mv=market[md];mp=market[days[mi[d]-2]]
                            sd=dates[n-1];quality=[]
                            if sd!=md:quality.append('stockPreviousDateNotLatestMarketDate')
                            if n<251 or int(mv['market_volume_observation_count'])<250:quality.append('volumeWarmup')
                            if prev['ZVOLUMECLOSE']<=0:quality.append('nonpositivePreviousVolume')
                            if r['ZVOLUMECLOSE']<=0:quality.append('zeroCurrentVolumeTradability')
                            if not all(r[k]>0 and math.isfinite(r[k]) for k in ('ZPRICEOPEN','ZPRICEHIGH','ZPRICELOW','ZPRICECLOSE')):quality.append('invalidOHLC')
                            assert sd<d and md<d
                            f={'phase':r['ZTPRICEPATHPHASERAW'],'mphase':int(paths[d]['phase_raw']),'grade':grade,'ma20':r['ZTMA20DIFF'],'ma60':r['ZTMA60DIFF'],'d20':r['ZTMA20DIFF']-prev['ZTMA20DIFF'],'osc':r['ZTOSCZ125'],'do':r['ZTOSCZ125']-prev['ZTOSCZ125'],'k':r['ZTKDK'],'dk':r['ZTKDK']-prev['ZTKDK'],'dz':r['ZTKDDZ125'],'kz':r['ZTKDKZ125'],'m20':float(m['market_ma_20_diff']),'m60':float(m['market_ma_60_diff']),'mo':float(m['market_osc_z_125']),'dm20':float(m['market_ma_20_diff'])-float(mv['market_ma_20_diff']), 'roi':h['unit_roi_before'],'age':h['holding_days_before'],'invests':h['invest_times_before'],'balance':h['balance_before']}
                            for name,col in [('svz','ZVZ125'),('svz250','ZVZ250'),('sv20','ZVMA20DIFF'),('sv60','ZVMA60DIFF'),('svdays','ZVMA20DAYS')]:f[name]=prev[col]
                            f['dsvz']=prev['ZVZ125']-raw[n-2]['ZVZ125'];f['svmin']=prev['ZVOLUMECLOSE']==prev['ZVMIN9'];f['svmax']=prev['ZVOLUMECLOSE']==prev['ZVMAX9']
                            for prefix,out in [('market_volume','mv'),('market_value','value'),('market_transaction','trans')]:
                                f[out+'z']=float(mv[prefix+'_z_125']);f[out+'20']=float(mv[prefix+'_ma_20_diff']);f[out+'60']=float(mv[prefix+'_ma_60_diff']);f['d'+out+'z']=float(mv[prefix+'_z_125'])-float(mp[prefix+'_z_125'])
                            mature=n>=249 and int(m['price_observation_count'])>=250
                            he1=mature and f['mphase']==7 and float(m['market_kd_j_z_250'])>-.88 and (grade>=1 or f['ma60']>-3.6)
                            he2=mature and r['ZTKDDZ125']<-.85 and -10<float(m['market_high_diff_250'])<-1.7 and (r['ZTHIGHDIFF']>2.2 or r['ZTLOWDIFFZ250']<-.92)
                            rec=dict(date=d,index=mi[d],round=roundid,segment=flatseg,price=r['ZPRICECLOSE'],features=f,stockVolumeDate=sd,marketVolumeDate=md,quality=quality,flat=flat,held=held,qtyBefore=h['inventory_before'],costBefore=prev['ZSIMAMTCOST'],qtyBuy=r['ZSIMQTYBUY'],qtySell=r['ZSIMQTYSELL'],investAdded=r['ZSIMINVESTADDED'],profit=r['ZSIMAMTPROFIT'],buyRule=r['ZSIMRULEBUY'],entryRule=h['buy_rule_before'],normalRule=r['ZSIMRULE'],gates={},votes={str(k):votes[v['event_id']] for k,v in es.items()})
                            if flat:
                                e=em[d];assert e['feasible'] or not r['ZSIMQTYBUY'];eq(e['price'],r['ZPRICECLOSE'])
                                hEarly=e['feasible'] and not e['normal'] and h['decision_score']+1>=h['decision_threshold'] and not he1 and not he2
                                l=es.get(2);lEarly=e['feasible'] and not e['normal'] and bool(l) and l['decision_score']+1>=5
                                rec.update(flatFeasible=e['feasible'],hEarly=bool(hEarly),lEarly=bool(lEarly),hDelay=bool(e['originalBuy']=='H'),lDelay=bool(e['originalBuy']=='L'),lFallbackProvenAbsent=l_upper(r,grade,d%10000)<5,hMargin=h['decision_score']-h['decision_threshold'],lMargin=l['decision_score']-5 if l else None)
                                uc['flatDays']+=1;uc['Hentries']+=e['originalBuy']=='H';uc['Lentries']+=e['originalBuy']=='L'
                            if held:
                                se=es[3];fit=fits[(w,st['ZSID'],d)];g=gates(se,fit,r,prev,n,gap,ms,d)
                                assert set(g['expected'])==gs[se['event_id']],(uid,d,'sell gates',g['expected'],gs[se['event_id']])
                                assert g['normalSell']==(r['ZSIMQTYSELL']>0),(uid,d,'sell action')
                                more=dict(se,decision_score=se['decision_score']+1);g1=gates(more,fit,r,prev,n,gap,ms,d)
                                rec.update(gates=g,sEarly=not g['normalSell'] and g1['normalSell'],sEarlyCategory='profit' if g1['base'] else 'loss' if g1['net']<0 else 'recovery',sDelay=g['normalSell'] and g['base'],lcDelay=g['normalSell'] and not g['base'] and g['net']<0,recoveryDelay=g['normalSell'] and not g['base'] and g['net']>=0,sellCategory='profit' if g['base'] else 'loss' if g['net']<0 else 'recovery')
                                uc['heldDays']+=1;uc['sellDays']+=g['normalSell'];uc['sellGateChecks']+=1
                                if d in am:
                                    a=am[d];eq(a['price'],r['ZPRICECLOSE']);assert not g['normalSell']
                                    extra=a['eligible'] and ((a['roiqual'] and a['features']['score']+1>=3) or (a['lowqual'] and a['features']['score']+1>=a['lowthreshold']))
                                    rec.update(aEarly=bool(extra),aDelay=a['actual'],addEligible=a['eligible'],addQuantity=a['qtyIfAdd'],addRoiQual=a['roiqual'],addLowQual=a['lowqual'],addScore=a['features']['score'],addGates=a['gates'])
                                    uc['addDays']+=1;uc['actualAdds']+=a['actual']
                            rows.append(rec);uc['days']+=1
                            for q in quality:uc['quality:'+q]+=1
                        if r['ZSIMINVESTADDED']+r['ZSIMINVESTBYUSER']==1:gap=0
                        elif r['ZSIMDAYS']<=1:gap=None
                        elif gap is not None:gap+=1
                    assert uc['days']==ea['counts']['decisionDays'] and uc['flatDays']==ea['counts']['flatDays']
                    assert uc['heldDays']==aa['counts']['heldDays'] and uc['actualAdds']==aa['counts'].get('actualAdds',0)
                    unit=dict(id=uid,sample=sample,window=w,stock=st['ZSID'],name=st['ZSNAME'],rows=rows,counts=dict(uc),identity=dict(store=HASH[str((rp/fn).relative_to(R))],base=HASH[str((bp/'decisions.sqlite').relative_to(R))]))
                    save('units/'+uid+'.json',unit);units.append(uid);total.update(uc);progress('extract',unit=uid,completed=len(units))
                    if len(units)==1:save('calibration.json',dict(resources=guard(),projectedUnitWallSeconds=(time.monotonic()-START)*150))
                    if limit and len(units)>=limit:
                        save('source-hashes.json',HASH);finish('calibration',units=units,counts=dict(total));return
    assert total['days']==sum(x['days'] for x in inv.values())
    for p,h in HASH.items():assert sha(R/p)==h,p
    save('source-hashes.json',HASH);finish('extraction',units=units,counts=dict(total),protectedSources=len(HASH))

if __name__=='__main__':
    try:
        if sys.argv[1]=='extract':extract(int(sys.argv[2]) if len(sys.argv)>2 else None)
    except Exception as e:
        save('failure-'+str(int(time.time()))+'.json',dict(stage=sys.argv[1:],error=repr(e),resources=usage()))
        raise
