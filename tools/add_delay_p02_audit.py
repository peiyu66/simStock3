#!/usr/bin/env python3
"""Independent source join, validity and observation-quality checks for AD-P02."""
import bisect
import csv
import json
import collections as C
import numpy as np
import add_delay_p01 as p

O=p.R/'exports/add-delay-p02-20261002'

def read(name):return json.loads((O/name).read_text())

def main():
    assert not (O/'audit.json').exists(),'Do not overwrite completed audit'
    done=read('completion.json');assert done['status']=='complete'
    for name,digest in done['artifacts'].items():assert p.sha(O/name)==digest,name
    for rel,digest in read('source-hashes.json').items():assert p.sha(p.R/rel)==digest,rel
    with (p.M/'market-daily.csv').open() as f:market=sorted(int(r['date'].replace('-','')) for r in csv.DictReader(f))
    ids=json.loads((p.O/'identities.json').read_text());raw={};before={}
    for sample in 'CD':
        with p.db(p.R/ids[sample]['decisionBase']/'decisions.sqlite') as db:
            for r in db.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=4'):
                before[(sample,r['window_id'],r['stock_id'],r['trade_date'])]=dict(r)
        for w,(filename,_,_) in enumerate(p.WINDOWS,1):
            with p.db(p.R/ids[sample]['report']/filename) as db:
                for r in db.execute('select s.ZSID sid,t.ZDATETIME dt,t.ZPRICECLOSE price,t.ZVOLUMECLOSE volume,t.ZDATASOURCE source,lag(t.ZDATETIME) over(partition by s.ZSID order by t.ZDATETIME) prev from ZTRADE t join ZSTOCK s on t.ZSTOCK=s.Z_PK'):
                    raw[(sample,w,r['sid'],p.day(r['dt']))]=dict(r)
    cat=read('feature-catalog.json');index={c['name']:j for j,c in enumerate(cat)};scols=[j for j,c in enumerate(cat) if c['group']=='S']
    checks=C.Counter();quality=[]
    for label in ('discovery','later'):
        keys=read(label+'-keys.json');a=np.load(O/(label+'.npz'));X=a['X']
        assert X.shape==(len(keys),292) and np.array_equal(a['valid'],np.isfinite(X))
        assert list(a['anchors'])==[i for i,k in enumerate(keys) if k['offset']==0]
        for i,k in enumerate(keys):
            key=tuple(k[n] for n in ('sample','window','stock','date'));r=raw[key]
            assert r['source']=='TWSE' and r['price']>0
            if k['offset']:
                assert np.isnan(X[i,scols]).all();checks['futureSRowsMasked']+=1
            else:
                b=before[key]
                for col in ('inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before'):
                    assert X[i,index[col]]==b[col];checks['ADDDirectPrestate']+=1
                assert X[i,index['buy_rule_before']]=={'H':1,'L':2}[b['buy_rule_before']]
                if b['grade']==0:assert np.isnan(X[i,index['s_grade']]);checks['noneGradeMasked']+=1
            prev=p.day(r['prev']) if r['prev'] is not None else None
            gaps=market[bisect.bisect_right(market,prev):bisect.bisect_left(market,k['date'])] if prev else []
            quality.append(dict(**k,volume=r['volume'],missingStockSessions=gaps,qualifiedObservation=r['volume']>0 and not gaps))
        for op in read(label+'-opportunities.json'):
            entries=[keys[i] for i in op['indices']]
            prices=[raw[tuple(k[n] for n in ('sample','window','stock','date'))]['price'] for k in entries]
            assert op['observedLower']==any(x<prices[0] for x in prices[1:]);checks['priceOpportunities']+=1
    assert checks['futureSRowsMasked']==1407 and checks['priceOpportunities']==143
    unknown=[q for q in quality if not q['qualifiedObservation']]
    report=dict(passed=True,checks=dict(checks),rows=len(quality),futureSFields=len(scols),
                nonpositiveVolumeRows=sum(q['volume']<=0 for q in quality),calendarGapRows=sum(bool(q['missingStockSessions']) for q in quality),
                unknownRows=unknown,sourceFilesUnchanged=done['sourcesUnchanged'],artifactHashesVerified=len(done['artifacts']),
                scope='Observed official closes only; does not assert candidate admission or actual execution',auditScriptSHA256=p.sha(p.R/'tools/add_delay_p02_audit.py'))
    (O/'audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='unknownRows'}))

if __name__=='__main__':main()
