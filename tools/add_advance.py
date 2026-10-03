#!/usr/bin/env python3
"""AA-P01. Read-only same-round early-add observations, never strategy replay."""
import collections as C
import csv,datetime as D,hashlib,json,math,resource,sqlite3,subprocess,time
from pathlib import Path
R=Path(__file__).resolve().parents[1]
O=R/'exports/add-advance-20261003'
RULE='7ba8447fbf207484ab305cad0c6beca216da8c93'
START=time.monotonic();CPU=time.process_time();HASH={}
resource.setrlimit(resource.RLIMIT_CPU,(1800,1800))
TF={'ma20':'ZTMA20DIFF','ma60':'ZTMA60DIFF','ma20Days':'ZTMA20DAYS','osc':'ZTOSCZ125','k':'ZTKDK','j':'ZTKDJ','kz':'ZTKDKZ125','dz':'ZTKDDZ125','vz':'ZVZ125','phase':'ZTPRICEPATHPHASERAW','v60':'ZVMA60DIFF','ma20z':'ZTMA20DIFFZ125','ma60z':'ZTMA60DIFFZ125'}
MF={'m20':'market_ma_20_diff','m60':'market_ma_60_diff','mo':'market_osc_z_125','mk':'market_kd_k','mjz':'market_kd_j_z_250'}
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def source(p):
 HASH[str(p.relative_to(R))]=sha(p);return p
def save(n,x):
 p=O/n;p.parent.mkdir(parents=True,exist_ok=True);t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(x,ensure_ascii=False,allow_nan=False,separators=(',',':'))+'\n');t.replace(p)
def db(p):
 source(p)
 for s in ('-wal','-shm'):
  q=Path(str(p)+s)
  if q.exists():
   source(q)
   if s=='-wal':assert q.stat().st_size==0,p
 c=sqlite3.connect(p.as_uri()+'?mode=ro&immutable=1',uri=True);c.row_factory=sqlite3.Row
 assert c.execute('pragma quick_check').fetchone()[0]=='ok';return c
def day(t):return int((D.datetime(2001,1,1)+D.timedelta(seconds=t,hours=8)).strftime('%Y%m%d'))
def eq(a,b):assert math.isclose(a,b,rel_tol=1e-10,abs_tol=1e-6),(a,b)
def rnd(x):return math.floor(x+.5)
def qty(price,balance,budget):
 one=price*1000+max(20,rnd(price*1.425));money=min(balance,budget)
 if balance<one:return 0
 q=max(0,math.floor(money/(price*1000*1.001425)))
 if q<math.ceil(20/(price*1.425)):q=max(0,math.floor((money-20)/(price*1000)))
 return 1 if q==0 and money>one else q
def guard():
 x={'wallSeconds':time.monotonic()-START,'cpuSeconds':time.process_time()-CPU,'peakRSSBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'allocatedBytes':sum(p.stat().st_blocks*512 for p in O.rglob('*') if p.is_file())}
 assert x['wallSeconds']<1800 and x['peakRSSBytes']<=512*1024**2 and x['allocatedBytes']<=256*1024**2,x
 return x
def main():
 assert not (O/'extraction-complete.json').exists(),'completed evidence immutable'
 inv=json.loads((O/'inventory.json').read_text());source(Path(__file__))
 for fn in ('technical.swift','dataModel.swift','RollingContext.swift','InternalBacktestDecisionBase.swift'):
  p=source(R/'simStock3'/fn);assert p.read_bytes()==subprocess.check_output(['git','show',RULE+':simStock3/'+fn],cwd=R)
 def cm(p):
  source(p)
  with p.open() as f:return {int(x['date'].replace('-','')):x for x in csv.DictReader(f)}
 market=cm(R/'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af/market-technical.csv')
 paths=cm(R/'exports/market-data/taiex/research/mkt-pp-p1-taiex-price-path-f712b360c322/market-price-path.csv')
 mdays=sorted(market);tot=C.Counter();units=[]
 for sample in 'CDABE':
  bp=R/inv[sample]['decisionBase'];rp=R/inv[sample]['report']
  for folder in (bp,rp):
   m=json.loads(source(folder/'manifest.json').read_text())
   for k,v in {'ruleCommit':RULE,'dataRuleVersion':'T3/S61','ruleVersion':'s49-sell-delay-f03-r1-20261001','sampleID':sample,'moneyBaseWan':600,'automaticInvestments':2,'through':'2026/07/22'}.items():assert m[k]==v,(k,m[k])
   source(folder/'.complete')
  source(rp/'baseline.json');source(rp/'periods.csv')
  with db(bp/'decisions.sqlite') as c:
   es={}
   for x in c.execute('select e.*,s.stock_id,s.group_name from decision_events e join stocks s using(stock_key) where phase in (3,4)'):
    es.setdefault((x['window_id'],x['stock_id'],x['trade_date']),{})[x['phase']]=dict(x)
   votes=C.defaultdict(dict)
   for x in c.execute('select v.event_id,r.rule_id,v.contribution from event_votes v join rules r using(rule_key) join decision_events e using(event_id) where e.phase=4'):votes[x[0]][x[1]]=x[2]
   gates=C.defaultdict(set)
   for x in c.execute('select g.event_id,r.rule_id from event_gates g join rules r using(rule_key) join decision_events e using(event_id) where e.phase=4'):gates[x[0]].add(x[1])
  for w,fn in enumerate(('browse.store','period-20200722.store','period-20230722.store'),1):
   with db(rp/fn) as c:
    for st in c.execute('select * from ZSTOCK'):
     assert st['ZTECHNICALSTATEVERSION']==3 and st['ZSIMULATIONSTATEVERSION']==61 and st['ZTECHNICALDIRTYFROM'] is None and st['ZSIMULATIONDIRTYFROM'] is None
     uid=f'{sample}-{w}-{st["ZSID"]}';identity={'tool':HASH[str(Path(__file__).relative_to(R))],'store':HASH[str((rp/fn).relative_to(R))],'base':HASH[str((bp/'decisions.sqlite').relative_to(R))]}
     done=O/'units'/f'{uid}.json'
     if done.exists():
      u=json.loads(done.read_text());assert u['identity']==identity;units.append(uid);tot.update(u['counts']);continue
     raw=[dict(x) for x in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],))]
     dates=[day(x['ZDATETIME']) for x in raw];date_set=set(dates);assert len(dates)==len(date_set)
     rows=[];events=[];counts=C.Counter();roundid=None;cool=None;lastbuy=None;history=[]
     for n,r in enumerate(raw):
      d=dates[n];eall=es.get((w,st['ZSID'],d));prev=raw[n-1] if n else None
      if not prev:continue
      inwindow=(20170722,20200722,20230722)[w-1]<=d<(20200722,20230722,20260722)[w-1]
      if not inwindow:continue
      if prev['ZSIMQTYINVENTORY']==0 and r['ZSIMQTYBUY']>0:roundid=d
      held=prev['ZSIMQTYINVENTORY']>0;sold=r['ZSIMQTYSELL']>0
      rec={'date':d,'round':roundid,'held':held,'sold':sold,'price':r['ZPRICECLOSE'],'eligible':False}
      if held:
       assert eall and 3 in eall,(uid,d,'missing held decision');counts['heldDays']+=1
       e=eall.get(4);assert bool(e)==(not sold),(uid,d,'sell precedence')
       if sold:counts['soldDays']+=1
       else:
        assert roundid is not None,(uid,d,'round')
        assert not r['ZSIMREVERSED'] and not r['ZSIMINVESTBYUSER'];assert r['ZDATASOURCE']=='TWSE'
        price=r['ZPRICECLOSE'];roi=100*(price-prev['ZSIMUNITCOST'])/prev['ZSIMUNITCOST'];age=prev['ZSIMDAYS']+round((r['ZDATETIME']-prev['ZDATETIME'])/86400)
        for a,b in [(e['unit_roi_before'],roi),(e['inventory_before'],prev['ZSIMQTYINVENTORY']),(e['unit_cost_before'],prev['ZSIMUNITCOST']),(e['holding_days_before'],age),(e['balance_before'],prev['ZSIMAMTBALANCE']),(e['invest_times_before'],prev['ZSIMINVESTTIMES'])]:eq(a,b)
        v=votes[e['event_id']];score=e['decision_score'];eq(score,sum(v.values()));g=gates[e['event_id']];grade=e['grade']
        roiqual=roi<(-32.5 if grade>=0 else -30) or roi< -25 and (age<180 or age>360)
        lowqual=-10<roi<1 and r['ZSIMRULE']=='L' and age<60;lowthreshold=2 if grade<=-2 else 3
        t1=roiqual and score>=3;t2=lowqual and score>=lowthreshold;normal=t1 or t2
        ae02=roi< -45 and grade>=1;ae04=roi< -50;ae=ae04 or ((cool is None or cool>=38 or ae02) and e['invest_times_before']<=2)
        assert t1==('A-T01' in g) and t2==('A-T02' in g)
        assert (normal and ae)==('A-E' in g)==(e['executed_action']=='ADD')==(r['ZSIMINVESTADDED']==1),(uid,d,'AE',cool,roi)
        assert (e['planned_action']=='ADD')==normal
        q=qty(price,e['balance_before']+6000000,(e['invest_times_before']+1)*6000000-prev['ZSIMAMTCOST'])
        actual=r['ZSIMQTYBUY']>0;assert actual==(normal and ae and q>0),(uid,d,'actual')
        if normal and ae:
         counts['capitalAdds']+=1
         if actual:
          eq(q,r['ZSIMQTYBUY']);cost=rnd(price*q*1000)+max(20,rnd(price*q*1.425))
          for a,b in [(r['ZSIMAMTBALANCE'],e['balance_before']+6000000-cost),(r['ZSIMQTYINVENTORY'],e['inventory_before']+q),(r['ZSIMAMTCOST'],prev['ZSIMAMTCOST']+cost),(r['ZSIMINVESTTIMES'],e['invest_times_before']+1)]:eq(a,b)
          counts['actualAdds']+=1
        m=market.get(d);mp=paths.get(d);quality=[]
        if not m or not mp:quality.append('missingMarket')
        if n<249 or m and int(m['price_observation_count'])<250:quality.append('immature')
        if r['ZVOLUMECLOSE']<=0:quality.append('zeroVolume')
        if not all(math.isfinite(r[k]) and r[k]>0 for k in ('ZPRICEOPEN','ZPRICEHIGH','ZPRICELOW','ZPRICECLOSE')) or not r['ZPRICELOW']<=min(r['ZPRICEOPEN'],price)<=max(r['ZPRICEOPEN'],price)<=r['ZPRICEHIGH']:quality.append('badOHLC')
        f={k:r[v] for k,v in TF.items()};f.update({k:float(m[v]) if m else None for k,v in MF.items()})
        f.update({'mphase':int(mp['phase_raw']) if mp else None,'grade':grade,'roi':roi,'age':age,'invests':e['invest_times_before'],'sinceBuy':n-lastbuy if lastbuy is not None else None,'sinceAdd':cool,'score':score,'d20':r['ZTMA20DIFF']-prev['ZTMA20DIFF'],'do':r['ZTOSCZ125']-prev['ZTOSCZ125'],'dk':r['ZTKDK']-prev['ZTKDK'],'dm20':float(m['market_ma_20_diff'])-float(market[dates[n-1]]['market_ma_20_diff']) if m and dates[n-1] in market else None,'dmo':float(m['market_osc_z_125'])-float(market[dates[n-1]]['market_osc_z_125']) if m and dates[n-1] in market else None})
        assert len(f)<=36
        eligible=ae and q>0 and not quality and not normal
        row={'date':d,'round':roundid,'price':price,'eligible':eligible,'normal':normal,'ae':ae,'ae02':ae02,'ae04':ae04,'qtyIfAdd':q,'quality':quality,'features':f,'votes':v,'roiqual':roiqual,'lowqual':lowqual,'lowthreshold':lowthreshold,'rule':r['ZSIMRULE'],'entryRule':e['buy_rule_before'],'actual':actual,'gates':sorted(g)}
        rows.append(row);rec.update({'eligible':eligible,'normal':normal,'ae':ae,'quality':quality,'actual':actual})
        counts['addDecisions']+=1;counts['eligible']+=eligible;counts['feasible']+=ae and q>0 and not quality
        if actual:
         prior=history[-10:];missing=[x for x in mdays if (prior[0]['date'] if prior else d)<x<d and x not in date_set]
         events.append({'date':d,'round':roundid,'price':price,'gate':'T1' if t1 else 'T2','prior':prior,'leftTruncated':len(prior)<10,'missingMarketSessions':missing,'invests':e['invest_times_before']})
      history.append(rec)
      if r['ZSIMQTYBUY']>0:lastbuy=n
      if r['ZSIMINVESTADDED']+r['ZSIMINVESTBYUSER']==1:cool=0
      elif r['ZSIMDAYS']<=1:cool=None
      elif cool is not None:cool+=1
     u={'identity':identity,'sample':sample,'window':w,'stock':st['ZSID'],'name':st['ZSNAME'],'counts':dict(counts),'rows':rows,'events':events};save('units/'+uid+'.json',u)
     units.append(uid);tot.update(counts);save('checkpoint.json',{'units':units,'last':uid,'resources':guard()});print(uid,dict(counts),flush=True)
     if len(units)==1:save('calibration.json',{'unit':uid,'resources':guard()})
 for s in 'ABCDE':
  us=[json.loads((O/'units'/f'{x}.json').read_text()) for x in units if x.startswith(s+'-')]
  for k in ('addDecisions','capitalAdds'):assert sum(u['counts'].get(k,0) for u in us)==inv[s][k]
 for p,h in HASH.items():assert sha(R/p)==h,p
 save('source-hashes.json',HASH);save('extraction-complete.json',{'units':units,'counts':dict(tot),'resources':guard(),'sourceProtection':True,'strategyReplay':False})
if __name__=='__main__':main()
