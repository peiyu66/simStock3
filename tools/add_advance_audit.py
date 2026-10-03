#!/usr/bin/env python3
"""Independent raw-store and event-window audit of AA-P01; never writes sources."""
import json,sqlite3,hashlib,datetime,collections,time
from pathlib import Path
R=Path(__file__).resolve().parents[1];O=R/'exports/add-advance-20261003'
def read(p):return json.loads(p.read_text())
def sha(p):return hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
def date(x):return int((datetime.datetime(2001,1,1)+datetime.timedelta(seconds=x,hours=8)).strftime('%Y%m%d'))
def main():
 start=time.monotonic();counts=collections.Counter();ident=read(O/'inventory.json');hashes=read(O/'source-hashes.json')
 for name,h in hashes.items():
  p=O/'extraction-tool-as-run.py' if name=='tools/add_advance.py' else R/name
  assert sha(p)==h,name
 for sample in 'ABCDE':
  for w,fn in enumerate(('browse.store','period-20200722.store','period-20230722.store'),1):
   p=R/ident[sample]['report']/fn
   with sqlite3.connect(p.as_uri()+'?mode=ro&immutable=1',uri=True) as c:
    c.row_factory=sqlite3.Row
    for s in c.execute('select Z_PK,ZSID from ZSTOCK'):
     u=read(O/'units'/f'{sample}-{w}-{s[1]}.json');assert u['identity']['store']==sha(p)
     raw=list(c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(s[0],)));starts=(20170722,20200722,20230722);ends=(20200722,20230722,20260722)
     indexed={date(r['ZDATETIME']):i for i,r in enumerate(raw)};us={r['date']:r for r in u['rows']};actual=[]
     for d,i in indexed.items():
      r=raw[i]
      if not starts[w-1]<=d<ends[w-1] or i==0:continue
      prev=raw[i-1]
      if r['ZSIMINVESTADDED']==1:
       assert r['ZSIMQTYBUY']>0;actual.append(d)
      if prev['ZSIMQTYINVENTORY']<=0 or r['ZSIMQTYSELL']>0:continue
      row=us[d];entry=next(date(raw[j]['ZDATETIME']) for j in range(i-1,0,-1) if raw[j]['ZSIMQTYBUY']>0 and raw[j-1]['ZSIMQTYINVENTORY']==0)
      assert entry==row['round'],(sample,w,s[1],d,'round')
      since=None
      for j in range(i-1,-1,-1):
       if raw[j]['ZSIMINVESTADDED']+raw[j]['ZSIMINVESTBYUSER']==1:since=i-1-j;break
       if raw[j]['ZSIMDAYS']<=1:break
      assert since==row['features']['sinceAdd'],(d,since,row['features']['sinceAdd'])
      counts['auditedDays']+=1
     assert actual==[e['date'] for e in u['events']]
     for e in u['events']:
      i=indexed[e['date']];prior=[date(r['ZDATETIME']) for r in raw[max(1,i-10):i] if starts[w-1]<=date(r['ZDATETIME'])<ends[w-1]]
      assert prior==[r['date'] for r in e['prior']]
      counts['events']+=1;counts['truncatedEvents']+=e['leftTruncated'];counts['missingPreDays']+=10-len(prior);counts['missingMarketSessions']+=len(e['missingMarketSessions'])
     counts['units']+=1
 assert counts['units']==150 and counts['events']==348 and counts['auditedDays']==91614
 out={'passed':True,'counts':dict(counts),'sourceHashesVerified':len(hashes),'asRunToolHash':sha(O/'extraction-tool-as-run.py'),'correctedToolHash':sha(R/'tools/add_advance.py'),'wallSeconds':time.monotonic()-start,'independentChecks':['raw held round','backward cooldown scan','actual capital buys','previous ten trading rows','source immutability']}
 (O/'independent-audit.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out))
if __name__=='__main__':main()
