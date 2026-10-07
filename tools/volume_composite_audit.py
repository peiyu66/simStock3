#!/usr/bin/env python3
"""Independent VCX alignment, first-action, source, and comparison audit."""
import collections as C,csv,json,math,statistics as S,functools
import volume_composite as v
import volume_composite_analysis as a
O=v.O
@functools.lru_cache(maxsize=1)
def unit(uid):return json.loads((O/'units'/(uid+'.json')).read_text())
def main():
    hashes=json.loads((O/'source-hashes.json').read_text())
    for p,h in hashes.items():assert v.sha(v.R/p)==h,p
    inventory=json.loads((O/'inventory.json').read_text());checks=C.Counter();unit_hashes={}
    mt=v.R/'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af'
    with (mt/'market-technical.csv').open() as f:market={int(r['date'].replace('-','')):r for r in csv.DictReader(f)}
    dates=sorted(market);previous=dict(zip(dates[1:],dates))
    # Re-read source columns by SQL independently of extraction; all feature rows.
    for sample in 'ABCDE':
        rp=v.R/inventory[sample]['report']
        for w,fn in enumerate(('browse.store','period-20200722.store','period-20230722.store'),1):
            with v.db(rp/fn) as db:
                for stock in db.execute('select Z_PK,ZSID from ZSTOCK'):
                    uid=f'{sample}-{w}-{stock[1]}';path=O/'units'/f'{uid}.json';u=json.loads(path.read_text());unit_hashes[uid]=v.sha(path)
                    raw=list(db.execute('select ZDATETIME,ZVZ125,ZVMA20DIFF,ZVMA60DIFF from ZTRADE where ZSTOCK=? order by ZDATETIME',(stock[0],)))
                    actual={v.day(r[0]):r for r in raw}
                    for r in u['rows']:
                        assert r['stockVolumeDate']<r['date'] and r['marketVolumeDate']==previous[r['date']]
                        assert ('stockPreviousDateNotLatestMarketDate' in r['quality'])==(r['stockVolumeDate']!=r['marketVolumeDate'])
                        src=actual[r['stockVolumeDate']]
                        for f,j in [('svz',1),('sv20',2),('sv60',3)]:v.eq(r['features'][f],src[j])
                        for f,k in [('mvz','market_volume_z_125'),('mv20','market_volume_ma_20_diff'),('valuez','market_value_z_125'),('transz','market_transaction_z_125')]:v.eq(r['features'][f],float(market[r['marketVolumeDate']][k]))
                        assert all(math.isfinite(x) for x in r['features'].values())
                        assert not (r.get('aEarly') and r['qtySell']>0)
                        checks['inputRows']+=1
    summaries=json.loads((O/'screening-summary.json').read_text());duplicates=C.defaultdict(list);decomp={}
    for s in summaries:
        card=json.loads((O/'cards'/(s['id']+'.json')).read_text());h=card['hypothesis'];full=card['variants']['full'];bg=card['variants']['background'];keys=set()
        for rec in full['records']:
            u=unit(rec['unit']);rows=u['rows'];pos=next(i for i,r in enumerate(rows) if r['date']==rec['date']);r=rows[pos]
            assert r.get(a.ACTIONS[h['action']]) and not r['quality']
            assert a.bg(h['background'],r['features']) and a.vol(h['volume'],r['features'])
            # Recompute the first trigger in its baseline episode, rather than trusting card order.
            earlier=[q for q in rows[:pos] if a.anchor_key(h['action'],q)==a.anchor_key(h['action'],r) and q.get(a.ACTIONS[h['action']]) and a.match(h,q)]
            assert not earlier,(h['id'],rec['unit'],rec['date'])
            assert not rec['afterDivergenceCandidateStateUsed']
            keys.add((rec['unit'],rec['date']));checks['anchorFirstChecks']+=1
        expected={}
        for rec in full['records']:expected.setdefault(rec['unit'],rec['date'])
        assert {(r['unit'],r['date']) for r in full['firsts']}==set(expected.items())
        assert a.stats(full['firsts'])==full['summary']['firstPerStockWindow']['all']
        duplicates[(h['action'],tuple(sorted(keys)))].append(h['id'])
        v.progress('audit-card',card=h['id'],anchors=checks['anchorFirstChecks'])
        if h['id'] in ('VCX-C6-2','VCX-C2-2','VCX-T4-3','VCX-C5-1','VCX-T6-1','VCX-T3-1'):
            rr=full['firsts'];same=[r for r in rr if r['withinOriginalEventHorizon']];out=[r for r in rr if not r['withinOriginalEventHorizon']]
            bystock=C.defaultdict(list)
            for r in rr:
                if r['effect'] is not None:bystock[r['stock']].append(r['effect'])
            removals={st:S.mean(r['effect'] for r in rr if r['stock']!=st and r['effect'] is not None) for st in bystock if len(bystock)>1}
            bgmap={(r['unit'],r['date']):r for r in bg['records']}
            paired=[dict(unit=r['unit'],date=r['date'],fullReleaseEffect=r['effect'],backgroundReleaseEffect=bgmap[(r['unit'],r['date'])]['effect']) for r in full['records'] if (r['unit'],r['date']) in bgmap]
            decomp[h['id']]=dict(sameEventFirst=a.stats(same),outsideEventFirst=a.stats(out),leaveOneStockOutMean=removals,pairedRelease=paired,firstStockCount=len(bystock),lagMax=max((r['lag'] for r in rr if r['lag'] is not None),default=None),strata={field:{str(key):a.stats([r for r in rr if r[field]==key]) for key in sorted(set(r[field] for r in rr),key=str)} for field in ('grade','invests','sellCategory')})
    # Boundary checks use synthetic available observations; source missingness is
    # represented by quality exclusions, not by substituting numeric zero.
    f={k:0. for k in ['svz','mvz','dsvz','sv20','mv20','dmvz','valuez','transz']}
    assert not a.vol('sv_low',f) and not a.vol('mv20_low',f)
    f['svz']=1;assert not a.vol('sv_high',f)
    f['svz']=1.00001;assert a.vol('sv_high',f)
    for p,h in hashes.items():assert v.sha(v.R/p)==h,p
    v.save('audit.json',dict(checks=dict(checks),sourceHashesUnchanged=len(hashes),unitHashes=unit_hashes,duplicateCompleteTriggerSets=[x for x in duplicates.values() if len(x)>1],boundaryChecks=4,strategyReplay=False))
    v.save('interpretation-checks.json',decomp);v.finish('audit',**dict(checks),protectedSources=len(hashes))
if __name__=='__main__':main()
