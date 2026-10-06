#!/usr/bin/env python3
"""Independent date, rolling-block, first-condition and first-release audit."""
import collections as C,datetime as D,hashlib,json,math,resource,sqlite3,time
from pathlib import Path
R=Path(__file__).resolve().parents[1];O=R/'exports/vri-long-20261006';V=R/'exports/vcx-p01-p04-20261005';OLD=R/'exports/vri-p00-p03-20261005'
START=time.monotonic();resource.setrlimit(resource.RLIMIT_CPU,(900,900))
def rd(p):return json.loads(p.read_text())
def day(x):return int((D.datetime(2001,1,1)+D.timedelta(seconds=x,hours=8)).strftime('%Y%m%d'))
def eq(a,b):assert math.isclose(a,b,abs_tol=1e-6,rel_tol=1e-9),(a,b)
def test(h,v,r,s,a):
 if a['quality']:return False
 f=a['stock'];high=h.endswith(('H1','H2'));extra=h.endswith('2')
 if high:
  price=r['price']>s['sellPrice'] and r['features']['d20']>0;single=f['v']>f['ma20'] and f['z125']>1
  temporal=all((f['days60']<=-5,f['deltaMA60']<0,f['ma20']<f['ma60'],f['days20']>0,f['days20']<5))
  if extra:temporal=temporal and max(f['deltaZ125'],f['deltaZ250'])<=0
 else:
  price=r['price']<=s['sellPrice'] and r['features']['d20']<0;single=f['v']<f['ma20'] and f['z125']<0
  exception=all((f['days60']>=5,f['deltaMA60']>0,f['ma20']>f['ma60'],f['days20']<0,f['days20']> -5))
  if extra:exception=exception and min(f['deltaZ125'],f['deltaZ250'])>=0
  temporal=not exception
 return {'price':price,'single':price and single,'temporal':price and temporal,'full':price and single and temporal}[v]
def main():
 assert rd(O/'evaluation-complete.json')['hypotheses']==4
 seg={s['id']:s for s in rd(OLD/'segments.json')};first=C.defaultdict(list);paths=C.defaultdict(list);checks=C.Counter()
 for f in rd(O/'first-condition-and-executable.json'):first[seg[f['segment']]['unit']].append(f)
 for p in (O/'paths').glob('*.json'):
  for a in rd(p):paths[a['unit']].append(a)
 for sample,x in rd(V/'inventory.json').items():
  for w,fn in enumerate(('browse.store','period-20200722.store','period-20230722.store'),1):
   p=R/x['report']/fn;c=sqlite3.connect(p.as_uri()+'?mode=ro&immutable=1',uri=True);c.row_factory=sqlite3.Row
   for st in c.execute('select Z_PK,ZSID from ZSTOCK'):
    uid=f'{sample}-{w}-{st["ZSID"]}';rows=rd(V/'units'/(uid+'.json'))['rows'];lt=rd(O/'units'/(uid+'.json'));data=[dict(a) for a in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],)) if a['ZDATASOURCE']=='TWSE' and math.isfinite(a['ZVOLUMECLOSE']) and a['ZVOLUMECLOSE']>=0];ix={day(a['ZDATETIME']):i for i,a in enumerate(data)}
    for r,a in zip(rows,lt):
     assert a['date']==r['date'];i=ix[r['stockVolumeDate']];f=a['stock'];assert f['date']==day(data[i]['ZDATETIME'])<r['date'];assert a['marketDate']==r['marketVolumeDate']
     for k in (20,60):eq(f[f'ma{k}'],data[i][f'ZVMA{k}']);eq(f[f'days{k}'],data[i][f'ZVMA{k}DAYS'])
     for k in (125,250):eq(f[f'z{k}'],data[i][f'ZVZ{k}'])
     if i>=288:
      eq(f['deltaMA60'],data[i]['ZVMA60']-data[i-20]['ZVMA60']);eq(f['deltaMA20'],data[i]['ZVMA20']-data[i-20]['ZVMA20'])
      for k in (125,250):eq(f[f'deltaZ{k}'],sum(data[j][f'ZVZ{k}'] for j in range(i-19,i+1))/20-sum(data[j][f'ZVZ{k}'] for j in range(i-39,i-19))/20)
      checks['rollingBlockPairs']+=1
     else:assert 'LT289Warmup' in a['quality']
     checks['days']+=1
    for f in first[uid]:
     s=seg[f['segment']];match=[i for i in s['flatIndices'] if test(f['hypothesis'],f['variant'],rows[i],s,lt[i])];assert f['conditionDays']==len(match) and f['firstCondition']==rows[match[0]]['date']
     kind='H' if f['hypothesis'].endswith(('H1','H2')) else 'L';expected=s['entryDate'] if s.get('entryRule')==kind and s['entryIndex'] in match else None;assert f['firstExecutable']==expected;checks['firstConditionsAndExecutable']+=1
    for a in paths[uid]:
     s=seg[a['id']];i=s['entryIndex'];end=s['roundEndIndex'] if s['roundEndIndex'] is not None else len(rows)-1
     assert test(a['hypothesis'],a['variant'],rows[i],s,lt[i]);j=next((j for j in range(i+1,end+1) if not test(a['hypothesis'],a['variant'],rows[j],s,lt[j])),None);assert a['releaseDate']==(rows[j]['date'] if j is not None else None)
     if j is not None:eq(a['delta'],100*(rows[j]['price']/s['entryPrice']-1))
     checks['releases']+=1
    checks['units']+=1
   c.close();print('LT-audit',sample,w,dict(checks),flush=True)
   assert time.monotonic()-START<900 and resource.getrusage(resource.RUSAGE_SELF).ru_maxrss<1073741824
 for name in ('source-hashes.json','analysis-source-hashes.json'):
  for p,d in rd(O/name).items():
   h=hashlib.sha256()
   with (R/p).open('rb') as f:
    for b in iter(lambda:f.read(1048576),b''):h.update(b)
   assert h.hexdigest()==d,p;checks['hashes']+=1
 out=dict(passed=True,checks=checks,wallSeconds=time.monotonic()-START,cpuSeconds=time.process_time(),peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,strategyReplay=False)
 (O/'audit.json').write_text(json.dumps(out,indent=2)+'\n');print(out)
if __name__=='__main__':
 try:main()
 except Exception as e:
  (O/('audit-failure-'+str(int(time.time()))+'.json')).write_text(json.dumps(dict(error=repr(e),wallSeconds=time.monotonic()-START),indent=2)+'\n');raise
