#!/usr/bin/env python3
"""Independent verification of VRI episode boundaries and formula release dates."""
import collections as C,datetime as D,hashlib,json,math,sqlite3,time,resource
from pathlib import Path
R=Path(__file__).resolve().parents[1];O=R/'exports/vri-p00-p03-20261005';V=R/'exports/vcx-p01-p04-20261005'
START=time.monotonic()
def rd(p):return json.loads(p.read_text())
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def day(x):return int((D.datetime(2001,1,1)+D.timedelta(seconds=x,hours=8)).strftime('%Y%m%d'))
def condition(h,variant,row,s):
 f=row['features'];v=[f['svz']<0,f['sv20']<0,f['svz']<0 and f['sv20']<0,f['svz']>1,f['svz']>1 and f['mvz']<=0,f['svz']>1 and f['mvz']>1,f['svz']>1,f['svz']>1 and f['dsvz']>=0,f['svz']>1 and f['mvz']>1]
 ids=['VRI-M1-1','VRI-M1-2','VRI-M1-3','VRI-M2-1','VRI-M2-2','VRI-M2-3','VRI-M3-1','VRI-M3-2','VRI-M3-3'];b=(row['price']>s['sellPrice'] and f['d20']>0) if not h.startswith('VRI-M3-') else (row['price']<=s['sellPrice'] and f['d20']<0)
 return not row['quality'] and (variant=='volumeOnly' or b) and (variant=='background' or v[ids.index(h)])
def main():
 seg=rd(O/'segments.json');sm={s['id']:s for s in seg};by=C.defaultdict(list)
 for s in seg:by[s['unit']].append(s)
 checks=C.Counter();inventory=rd(V/'inventory.json')
 for sample,x in inventory.items():
  for w,fn in enumerate(('browse.store','period-20200722.store','period-20230722.store'),1):
   p=R/x['report']/fn;c=sqlite3.connect(p.as_uri()+'?immutable=1&mode=ro',uri=True)
   for pk,sid in c.execute('select Z_PK,ZSID from ZSTOCK'):
    data=list(c.execute('select ZDATETIME,ZSIMQTYBUY,ZSIMQTYSELL,ZSIMQTYINVENTORY,ZPRICECLOSE,ZSIMAMTPROFIT,ZDATASOURCE from ZTRADE where ZSTOCK=? order by ZDATETIME',(pk,)))
    uid=f'{sample}-{w}-{sid}';u=rd(V/'units'/(uid+'.json'));valid={r['date'] for r in u['rows']};data=[(day(a),b,d,e,f,g,h) for a,b,d,e,f,g,h in data if day(a) in valid]
    sales=[i for i,x in enumerate(data) if x[2]>0];assert len(sales)==len(by[uid])
    for si,s in zip(sales,by[uid]):
     assert s['sellDate']==data[si][0] and data[si][3]==0
     bi=next((j for j in range(si+1,len(data)) if data[j][1]>0),None)
     assert s['entryDate']==(data[bi][0] if bi is not None else None)
     fi=[i for i in range(si+1,(bi+1 if bi is not None else len(data))) if data[i-1][3]==0]
     assert s['flatIndices']==fi
     if bi is not None:
      ei=next((j for j in range(bi+1,len(data)) if data[j][2]>0),None)
      assert s['roundEndIndex']==ei;assert math.isclose(s['roundProfit'],data[ei if ei is not None else -1][5],abs_tol=1e-6)
     checks['segments']+=1
    checks['stockWindows']+=1
   c.close()
   print('audit-boundaries',sample,w,dict(checks),flush=True)
 # Unit-at-a-time independent masks and first-release proof, including all
 # rows before the chosen endpoint. No baseline S eligibility is consulted.
 paths=[]
 for p in sorted((O/'paths').glob('*.json')):paths.extend(rd(p))
 pb=C.defaultdict(list)
 for p in paths:pb[p['unit']].append(p)
 first=rd(O/'first-condition-and-executable.json');fb=C.defaultdict(list)
 for a in first:fb[sm[a['segment']]['unit']].append(a)
 for uid,episodes in by.items():
  rows=rd(V/'units'/(uid+'.json'))['rows']
  for p in pb[uid]:
   s=sm[p['id']];i=s['entryIndex'];end=s['roundEndIndex'] if s['roundEndIndex'] is not None else len(rows)-1
   assert condition(p['hypothesis'],p['variant'],rows[i],s)
   dates=[rows[j]['date'] for j in range(i+1,end+1) if not condition(p['hypothesis'],p['variant'],rows[j],s)]
   assert p['releaseDate']==(dates[0] if dates else None)
   checks['releaseFirstChecks']+=1
  for a in fb[uid]:
   s=sm[a['segment']];matches=[i for i in s['flatIndices'] if condition(a['hypothesis'],a['variant'],rows[i],s)]
   assert rows[matches[0]]['date']==a['firstConditionDate'] and len(matches)==a['conditionDays'];checks['conditionFirstChecks']+=1
   kind='L' if a['hypothesis'].startswith('VRI-M3-') else 'H'
   expected=s['entryDate'] if s.get('entryRule')==kind and s['entryIndex'] in matches else None
   assert a['firstExecutableDate']==expected;checks['executableFirstChecks']+=1
 for fn in ('source-hashes.json','source-hashes-analysis.json'):
  for p,d in rd(O/fn).items():assert sha(R/p)==d,p;checks['sourceHashChecks']+=1
 result=dict(passed=True,checks=checks,wallSeconds=time.monotonic()-START,cpuSeconds=time.process_time(),peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,strategyReplay=False)
 (O/'audit.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
if __name__=='__main__':main()
