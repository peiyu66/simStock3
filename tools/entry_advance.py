#!/usr/bin/env python3
"""EA: bounded, read-only baseline entry opportunities; never strategy replay."""
import collections as C,csv,datetime as D,hashlib,json,math,resource,sqlite3,subprocess,time
from pathlib import Path
R=Path(__file__).resolve().parents[1];O=R/'exports/entry-advance-20261003';START=time.monotonic();CPU=time.process_time();HASH={}
RULE='7ba8447fbf207484ab305cad0c6beca216da8c93'
FIELDS={'ma20':'ZTMA20DIFF','ma60':'ZTMA60DIFF','ma20Days':'ZTMA20DAYS','osc':'ZTOSCZ125','k':'ZTKDK','j':'ZTKDJ','kz':'ZTKDKZ125','dz':'ZTKDDZ125','vz':'ZVZ125','phase':'ZTPRICEPATHPHASERAW'}
MF={'m20':'market_ma_20_diff','m60':'market_ma_60_diff','mo':'market_osc_z_125','mk':'market_kd_k','mjz':'market_kd_j_z_250'}
resource.setrlimit(resource.RLIMIT_CPU,(1800,1800))
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def source(p):HASH[str(p.relative_to(R))]=sha(p);return p
def save(name,v):
 p=O/name;p.parent.mkdir(parents=True,exist_ok=True);t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(v,ensure_ascii=False,allow_nan=False,separators=(',',':'))+'\n');t.replace(p)
def guard():
 u={'cpuSeconds':time.process_time()-CPU,'wallSeconds':time.monotonic()-START,'peakRSSBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'allocatedBytes':sum(p.stat().st_blocks*512 for p in O.rglob('*') if p.is_file())}
 assert u['cpuSeconds']<1800 and u['peakRSSBytes']<=512*1024**2 and u['allocatedBytes']<=128*1024**2,u
 return u
def db(p):
 source(p);wal=Path(str(p)+'-wal');assert not wal.exists() or wal.stat().st_size==0,p
 c=sqlite3.connect(p.as_uri()+'?mode=ro&immutable=1',uri=True);c.row_factory=sqlite3.Row;assert c.execute('pragma quick_check').fetchone()[0]=='ok';return c
def day(t):return int((D.datetime(2001,1,1)+D.timedelta(seconds=t,hours=8)).strftime('%Y%m%d'))
def eq(a,b):assert math.isclose(a,b,rel_tol=1e-10,abs_tol=1e-6),(a,b)
def qty(price,balance,budget):
 one=price*1000+max(20,math.floor(price*1.425+.5));money=min(balance,budget)
 if balance<one:return 0
 q=max(0,math.floor(money/(price*1000*1.001425)))
 if q<math.ceil(20/(price*1.425)):q=max(0,math.floor((money-20)/(price*1000)))
 return 1 if q==0 and money>one else q

def main():
 assert not (O/'extraction-complete.json').exists(),'completed evidence is immutable'
 inv=json.loads((O/'inventory.json').read_text());source(Path(__file__));units=[];total=C.Counter()
 for name in ('technical.swift','HEntryDelayRule.swift','HEntryIncrementalDelayRule.swift','InternalBacktestDecisionBase.swift'):
  p=source(R/'simStock3'/name);assert p.read_bytes()==subprocess.check_output(['git','show',RULE+':simStock3/'+name],cwd=R)
 market=R/'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af/market-technical.csv'
 mp=R/'exports/market-data/taiex/research/mkt-pp-p1-taiex-price-path-f712b360c322/market-price-path.csv'
 def csvmap(p):
  source(p)
  with p.open() as f:return {int(x['date'].replace('-','')):x for x in csv.DictReader(f)}
 markets=csvmap(market);paths=csvmap(mp);mdays=sorted(markets);midx={d:i for i,d in enumerate(mdays)}
 for sample in 'ABCDE':
  bp=R/inv[sample]['decisionBase'];rp=next(R.glob('exports/backtest-reports/baseline-'+sample.lower()+'-v37-*-fixed3y-*'))
  with db(bp/'decisions.sqlite') as c:
   ev={}
   for e in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase in (1,2)'):
    ev.setdefault((e['window_id'],e['stock_id'],e['trade_date']),{})[e['phase']]=dict(e)
   votes=dict(c.execute('select event_id,sum(contribution) from event_votes group by event_id'))
   gates=C.defaultdict(set)
   for e,r in c.execute('select event_id,rule_id from event_gates join rules using(rule_key)'):gates[e].add(r)
  for w,fn in enumerate(('browse.store','period-20200722.store','period-20230722.store'),1):
   with db(rp/fn) as c:
    for s in c.execute('select * from ZSTOCK'):
     assert s['ZTECHNICALSTATEVERSION']==3 and s['ZSIMULATIONSTATEVERSION']==61 and s['ZTECHNICALDIRTYFROM'] is None and s['ZSIMULATIONDIRTYFROM'] is None
     uid=f'{sample}-{w}-{s["ZSID"]}';done=O/'units'/f'{uid}.json';identity={'tool':HASH[str(Path(__file__).relative_to(R))],'store':HASH[str((rp/fn).relative_to(R))],'base':HASH[str((bp/'decisions.sqlite').relative_to(R))]}
     if done.exists():
      u=json.loads(done.read_text());assert u['identity']==identity;units.append(uid);total.update(u['counts']);continue
     raw=[dict(x) for x in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(s['Z_PK'],))];dates=[day(x['ZDATETIME']) for x in raw];assert len(set(dates))==len(dates)
     counts=C.Counter();rows=[];events=[];history=[];segment=0;prevflat=False
     for n,r in enumerate(raw):
      d=dates[n];es=ev.get((w,s['ZSID'],d));
      if not es:continue
      h=es[1];l=es.get(2);prev=raw[n-1];price=r['ZPRICECLOSE'];flat=h['inventory_before']==0;counts['decisionDays']+=1
      assert not r['ZSIMREVERSED'] and not r['ZSIMINVESTBYUSER'] and r['ZDATASOURCE']=='TWSE'
      eq(h['inventory_before'],prev['ZSIMQTYINVENTORY']);eq(h['balance_before'],6000000 if prev['ZSIMRULE']=='_' else prev['ZSIMAMTBALANCE'])
      for e in es.values():eq(e['decision_score'],votes.get(e['event_id'],0));counts['voteChecks']+=1
      ht=1 if h['grade']==-2 else 0;eq(h['decision_threshold'],ht)
      if l:assert l['grade']==h['grade'] and l['inventory_before']==h['inventory_before'];eq(l['decision_threshold'],5)
      if flat and not prevflat:segment+=1
      prevflat=flat
      budget=json.loads((bp/'manifest.json').read_text())['moneyBaseWan']*10000;assert budget==6000000
      withdraw=(1-h['invest_times_before'])*budget if prev['ZSIMQTYSELL']>0 and h['invest_times_before']>1 else 0
      balance=h['balance_before']+withdraw
      q=qty(price,balance,budget) if flat and price>0 else 0
      cooldown=prev['ZSIMQTYSELL']>0 and prev['ZSIMREVERSED']==''
      feasible=flat and not cooldown and q>0
      m=markets.get(d);mpath=paths.get(d);quality=[]
      if not m or not mpath:quality.append('missingMarket')
      if n<249:quality.append('immatureStock')
      if r['ZVOLUMECLOSE']<=0:quality.append('zeroVolume')
      if not all(math.isfinite(r[k]) and r[k]>0 for k in ('ZPRICEOPEN','ZPRICEHIGH','ZPRICELOW','ZPRICECLOSE')) or not r['ZPRICELOW']<=min(r['ZPRICEOPEN'],price)<=max(r['ZPRICEOPEN'],price)<=r['ZPRICEHIGH']:quality.append('invalidOHLC')
      mature=n>=249 and m and int(m['price_observation_count'])>=250
      e1=bool(flat and feasible and h['decision_score']>=ht and mature and int(mpath['phase_raw'])==7 and float(m['market_kd_j_z_250'])>-.88 and (h['grade']>=1 or r['ZTMA60DIFF']>-3.6))
      e2=bool(flat and feasible and h['decision_score']>=ht and not e1 and mature and r['ZTKDDZ125']<-.85 and -10<float(m['market_high_diff_250'])<-1.7 and (r['ZTHIGHDIFF']>2.2 or r['ZTLOWDIFFZ250']<-.92))
      # Delay only applies to feasible flat entries; held gates remain recorded baseline.
      if flat:
       assert ('H-E01' in gates[h['event_id']])==e1,(uid,d,'E01')
       assert ('H-E02' in gates[h['event_id']])==e2,(uid,d,'E02')
       assert (h['planned_action']=='H')==(h['decision_score']>=ht and not e1 and not e2)
       assert bool(l)==(h['planned_action']!='H')
       if l:assert (l['planned_action']=='L')==(l['decision_score']>=5)
       normal=h['planned_action']=='H' or bool(l and l['planned_action']=='L')
       actual=r['ZSIMQTYBUY']>0
       assert actual==(feasible and normal),(uid,d,'execution',q,r['ZSIMQTYBUY'])
       assert actual==any(e['executed_action']=='BUY' for e in es.values())
       if actual:
        eq(r['ZSIMQTYBUY'],q);cost=math.floor(price*q*1000+.5)+max(20,math.floor(price*q*1.425+.5));eq(r['ZSIMAMTBALANCE'],balance-cost);counts['entryAccounting']+=1
       counts['flatDays']+=1;counts['feasibleDays']+=feasible;counts['blockedBoth']+=bool(feasible and not normal and not quality)
       f={k:r[v] for k,v in FIELDS.items()};f.update({k:float(m[v]) if m else None for k,v in MF.items()});f.update({'mphase':int(mpath['phase_raw']) if mpath else None,'grade':h['grade'],'hMargin':h['decision_score']-ht,'lMargin':l['decision_score']-5 if l else None,'d20':r['ZTMA20DIFF']-prev['ZTMA20DIFF'],'do':r['ZTOSCZ125']-prev['ZTOSCZ125'],'dk':r['ZTKDK']-prev['ZTKDK'],'dm20':float(m['market_ma_20_diff'])-float(markets[dates[n-1]]['market_ma_20_diff']) if m and dates[n-1] in markets else None,'dmo':float(m['market_osc_z_125'])-float(markets[dates[n-1]]['market_osc_z_125']) if m and dates[n-1] in markets else None});assert len(f)==24
       row={'date':d,'segment':segment,'price':price,'qty':q,'balance':balance,'cooldown':cooldown,'feasible':feasible,'quality':quality,'normal':normal,'e1':e1,'e2':e2,'features':f,'hVotes':sorted(gates[h['event_id']]),'originalBuy':r['ZSIMRULEBUY'] if actual else None}
       rows.append(row)
      rec={'date':d,'flat':flat,'feasible':feasible,'quality':quality,'price':price,'segment':segment if flat else None,'normal':(h['planned_action']=='H' or bool(l and l['planned_action']=='L'))}
      if flat and r['ZSIMQTYBUY']>0:
       before=history[-10:];missing=[x for x in mdays if (before[0]['date'] if before else d)<x<d and x not in dates]
       event={'date':d,'rule':r['ZSIMRULEBUY'],'price':price,'segment':segment,'prior':before,'leftTruncated':len(before)<10,'missingMarketSessions':missing,'marketSpan':midx[d]-midx[before[0]['date']] if before and d in midx and before[0]['date'] in midx else None}
       assert event['rule'] in ('H','L');events.append(event);counts[event['rule']+'entries']+=1
      history.append(rec)
     u={'identity':identity,'sample':sample,'window':w,'stock':s['ZSID'],'name':s['ZSNAME'],'counts':dict(counts),'rows':rows,'events':events};save('units/'+uid+'.json',u);units.append(uid);total.update(counts)
     save('checkpoint.json',{'units':units,'last':uid,'resources':guard()});print(uid,dict(counts),flush=True)
     if len(units)==1:save('calibration.json',{'unit':uid,'resources':guard(),'features':list(rows[0]['features'])})
 for sample in 'ABCDE':
  us=[json.loads((O/'units'/f'{uid}.json').read_text()) for uid in units if uid.startswith(sample+'-')]
  assert sum(u['counts']['decisionDays'] for u in us)==inv[sample]['fixedDecisionDays']
  assert sum(u['counts']['flatDays'] for u in us)==inv[sample]['flatDays']
  for phase,expected in inv[sample]['entries']:assert sum(u['counts'].get(('H' if phase==1 else 'L')+'entries',0) for u in us)==expected
 for p,h in HASH.items():assert sha(R/p)==h,p
 save('source-hashes.json',HASH);save('extraction-complete.json',{'units':units,'counts':dict(total),'resources':guard(),'sourceProtection':True,'strategyReplay':False})
if __name__=='__main__':main()
