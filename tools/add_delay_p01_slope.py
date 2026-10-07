#!/usr/bin/env python3
"""Bounded predeclared three-formula follow-up; future S remains unknown."""
import collections as C
import csv
import json
import math
import add_delay_p01 as p

def main():
    assert not (p.O/'slope-completion.json').exists()
    frozen=p.read(p.O/'slope-specs.json'); events=p.read(p.O/'events.json')
    identities=p.read(p.O/'identities.json')
    with p.source(p.M/'market-technical.csv').open() as f:ms=list(csv.DictReader(f))
    market={};prev=None
    for r in ms:
        d=int(r['date'].replace('-',''))
        mature=int(r['price_observation_count'])>=250 and prev and int(prev['price_observation_count'])>=250
        market[d]=dict(delta_market_osc=float(r['market_osc'])-float(prev['market_osc']) if mature else None,
                       delta_market_kd_j=float(r['market_kd_j'])-float(prev['market_kd_j']) if mature else None)
        prev=r
    values={};checks=0
    for sample in 'CD':
        for w,(fn,_,_) in enumerate(p.WINDOWS,1):
            with p.db(p.R/identities[sample]['report']/fn) as c:
                # LAG uses the complete price preparation history, before date filtering.
                sql='''WITH series AS (
                    SELECT s.ZSID sid,t.ZDATETIME dt,t.ZTKDJ j,t.ZTOSC osc,
                    lag(t.ZTKDJ) OVER(PARTITION BY s.ZSID ORDER BY t.ZDATETIME) pj,
                    lag(t.ZTOSC) OVER(PARTITION BY s.ZSID ORDER BY t.ZDATETIME) po,
                    row_number() OVER(PARTITION BY s.ZSID ORDER BY t.ZDATETIME) n
                    FROM ZTRADE t JOIN ZSTOCK s ON t.ZSTOCK=s.Z_PK
                ) SELECT * FROM series ORDER BY sid,dt'''
                last={}
                for r in c.execute(sql):
                    d=p.day(r['dt']);ready=r['n']>=251
                    v=dict(delta_kd_j=r['j']-r['pj'] if ready else None,delta_osc=r['osc']-r['po'] if ready else None)
                    if ready:
                        old=last[r['sid']];assert v['delta_kd_j']==r['j']-old[0] and v['delta_osc']==r['osc']-old[1]
                        checks+=2
                    last[r['sid']]=(r['j'],r['osc'])
                    v.update(market.get(d,dict(delta_market_osc=None,delta_market_kd_j=None)))
                    values[(sample,w,r['sid'],d)]=v
    rows=[];formula_count=0
    for spec in frozen['candidates']:
        for e in events:
            key=tuple(e[k] for k in ('sample','window','stock','date'));f=values[key]
            matched=p.evaluate(spec,f);formula_count+=1
            # Independent direct conjunction; strict zero and NaN semantics.
            vs=[f[t[0]] for t in spec['terms']]
            assert matched==(None if not all(p.finite(v) for v in vs) else vs[0]<0 and vs[1]<0)
            out={k:e[k] for k in ('sample','window','stock','date','gateType','hasLower','futureCount')}
            out.update(candidate=spec['id'],features=f,matched=matched,release='not-triggered',releaseOffset=None,releaseChangePct=None,
                       lowBeforeHigherRelease=False,lowAfterHigherRelease=False,baselineExitBeforeRelease=False)
            if matched:
                out['release']='censored' if e['futureCount']<10 else 'no-release-within-ten'
                for x in e['future']:
                    v=p.evaluate(spec,values[(e['sample'],e['window'],e['stock'],x['date'])]);formula_count+=1
                    if v is None:out['release']='unknown-input';break
                    if not v:
                        out.update(release='lower' if x['price']<e['price'] else 'higher' if x['price']>e['price'] else 'equal',releaseOffset=x['offset'],releaseChangePct=x['changePct'])
                        out['lowBeforeHigherRelease']=out['release']=='higher' and any(y['price']<e['price'] and y['offset']<x['offset'] for y in e['future'])
                        out['lowAfterHigherRelease']=out['release']=='higher' and any(y['price']<e['price'] and y['offset']>x['offset'] for y in e['future'])
                        out['baselineExitBeforeRelease']=e['originalExitOffset'] is not None and e['originalExitOffset']<=x['offset']
                        break
            rows.append(out)
    assert formula_count<=frozen['maxFormulaRows']
    summaries=[]
    for spec in frozen['candidates']:
        entry=dict(id=spec['id'],hypothesis=spec['hypothesis'],source=spec['source'])
        for name,ws in [('discovery',(1,2)),('laterWindow',(3,)),('all',(1,2,3))]:
            rs=[r for r in rows if r['candidate']==spec['id'] and r['window'] in ws];hit=[r for r in rs if r['matched']]
            entry[name]=dict(hits=len(hit),unknown=sum(r['matched'] is None for r in rs),stocks=len({r['stock'] for r in hit}),dates=len({r['date'] for r in hit}),
                completeLower=sum(r['hasLower'] and r['futureCount']==10 for r in hit),completeNoLower=sum(not r['hasLower'] and r['futureCount']==10 for r in hit),
                censored=sum(r['futureCount']<10 for r in hit),release=dict(C.Counter(r['release'] for r in hit)),
                missedEarlierLow=sum(r['lowBeforeHigherRelease'] for r in hit),releasedBeforeLaterLow=sum(r['lowAfterHigherRelease'] for r in hit),
                baselineExitBeforeRelease=sum(r['baselineExitBeforeRelease'] for r in hit),gateTypes=dict(C.Counter(r['gateType'] for r in hit)))
        summaries.append(entry)
    p.save('slope-events.json',rows);p.save('slope-summary.json',summaries)
    for rel,digest in p.HASH.items():assert p.sha(p.R/rel)==digest,rel
    p.save('slope-source-hashes.json',p.HASH)
    p.save('slope-completion.json',dict(passed=True,formulaRows=formula_count,newFormulas=3,sqlLagVersusPythonChecks=checks,sourceHashesUnchanged=len(p.HASH),strategyReplays=0,
        specsHash=p.sha(p.O/'slope-specs.json'),artifactHashes={n:p.sha(p.O/n) for n in ('slope-events.json','slope-summary.json','slope-source-hashes.json')}))
    print(json.dumps(summaries,ensure_ascii=False))

if __name__=='__main__':main()
