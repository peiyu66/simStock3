#!/usr/bin/env python3
"""Independent SQL extraction and explicit formula audit for AD-P01."""
import collections as C
import json
import math
import sqlite3
from pathlib import Path
import add_delay_p01 as p

def main():
    expected=json.loads((p.O/'events.json').read_text())
    results=json.loads((p.O/'candidate-events.json').read_text())
    observed={};checks=C.Counter()
    for sample in 'CD':
        report=p.R/'exports/backtest-reports'/f'baseline-{sample.lower()}-v37-s49-sell-delay-f03-r1-t3s61-9y-fixed3y-600w-20261001'
        for w,(fn,start,end) in enumerate(p.WINDOWS,1):
            path=report/fn
            assert not Path(str(path)+'-wal').exists() or Path(str(path)+'-wal').stat().st_size==0
            with sqlite3.connect(path.as_uri()+'?mode=ro&immutable=1',uri=True) as c:
                c.row_factory=sqlite3.Row
                sql='''WITH dated AS (
                    SELECT t.*,s.ZSID sid,CAST(strftime('%Y%m%d',t.ZDATETIME+978307200,'unixepoch','+8 hours') AS INTEGER) d
                    FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK
                ), framed AS (
                    SELECT *,lag(ZSIMQTYINVENTORY) OVER(PARTITION BY sid ORDER BY d) previous_inventory,
                    count(*) OVER(PARTITION BY sid ORDER BY d ROWS BETWEEN 1 FOLLOWING AND 10 FOLLOWING) future_count,
                    min(ZPRICECLOSE) OVER(PARTITION BY sid ORDER BY d ROWS BETWEEN 1 FOLLOWING AND 10 FOLLOWING) future_min
                    FROM dated WHERE d<=?
                ) SELECT * FROM framed WHERE d>=? AND previous_inventory>0 AND ZSIMQTYBUY>0
                AND coalesce(ZSIMREVERSED,'')='' AND coalesce(ZSIMINVESTBYUSER,0)=0'''
                for r in c.execute(sql,(end,start)):
                    assert r['ZSIMINVESTADDED']==1 and r['ZSIMQTYSELL']==0
                    observed[(sample,w,r['sid'],r['d'])]=dict(r)
    assert set(observed)=={(e['sample'],e['window'],e['stock'],e['date']) for e in expected}
    bykey={}
    for e in expected:
        key=tuple(e[x] for x in ('sample','window','stock','date'));bykey[key]=e;r=observed[key]
        assert r['future_count']==e['futureCount'] and r['future_min']==e['minimumClose']
        assert (r['future_min'] is not None and r['future_min']<r['ZPRICECLOSE'])==e['hasLower']
        assert e['minimumDates']==[x['date'] for x in e['future'] if x['price']==e['minimumClose']]
        assert e['firstLower']==next((x['offset'] for x in e['future'] if x['price']<e['price']),None)
        checks['eventsFromIndependentSQL']+=1;checks['futureRows']=checks['futureRows']+e['futureCount']
    explicit={
        'AD-F01':lambda f:f['kd_j']<20 and f['osc']<0,
        'AD-F02':lambda f:f['market_phase'] in (6,7) and f['market_osc']<0,
        'AD-F03':lambda f:f['kd_j']<20 and f['market_osc']<0,
        'AD-F04':lambda f:f['unit_roi_before']< -25 and f['kd_j']<20,
        'AD-F05':lambda f:f['grade']<0 and f['prior_fit_trend']<0,
        'AD-F06':lambda f:f['grade']<0 and f['market_osc']<0,
        'AD-F07':lambda f:f['grade']<0 and f['kd_j']<20 and f['market_osc']<0,
        'AD-F08':lambda f:(f['kd_j']<20 and f['osc']<0) or (f['market_phase'] in (6,7) and f['market_osc']<0),
    }
    specs={s['id']:s for s in json.loads((p.O/'candidate-specs.json').read_text())}
    def direct(cid,f):
        names={x[0] for x in p.terms(specs[cid])}
        if any(not p.finite(f.get(n)) for n in names):return None
        return explicit[cid](f)
    for r in results:
        key=tuple(r[x] for x in ('sample','window','stock','date'));e=bykey[key];cid=r['candidate']
        assert direct(cid,e['features'])==r['matched'];checks['explicitOriginalFormulaChecks']+=1
        if not r['matched']:continue
        if cid in ('AD-F04','AD-F05','AD-F06','AD-F07'):
            assert r['release']=='unknown-own-S'
            assert all(x['features']['grade'] is None and x['features']['unit_roi_before'] is None for x in e['future'])
        else:
            decisions=[(x,direct(cid,x['features'])) for x in e['future']]
            resolved=next(((x,v) for x,v in decisions if v is not True),None)
            if resolved:
                x,v=resolved
                if v is None:assert r['release']=='unknown-input'
                else:
                    assert x['offset']==r['releaseOffset'] and x['changePct']==r['releaseChangePct']
                    assert r['release']==('lower' if x['price']<e['price'] else 'higher' if x['price']>e['price'] else 'equal')
            else:assert r['release']==('censored' if e['futureCount']<10 else 'no-release-within-ten')
            checks['releasePathsVerified']+=1
    # Explicit boundary/unknown contract, including an OR with one valid true branch.
    base=dict(kd_j=19,osc=-1,market_phase=6,market_osc=-1,unit_roi_before=-26,grade=-1,prior_fit_trend=-.1)
    assert p.evaluate(specs['AD-F01'],dict(base,kd_j=20)) is False
    assert p.evaluate(specs['AD-F04'],dict(base,unit_roi_before=-25)) is False
    assert p.evaluate(specs['AD-F05'],dict(base,grade=0)) is False
    assert p.evaluate(specs['AD-F08'],dict(base,market_osc=None)) is None
    assert p.evaluate(specs['AD-F08'],dict(base,osc=float('nan'))) is None
    checks['boundaryAndMissingControls']=5
    hashes=json.loads((p.O/'source-hashes.json').read_text())
    for rel,digest in hashes.items():assert p.sha(p.R/rel)==digest,rel
    checks['sourcesUnchanged']=len(hashes)
    p.save('audit.json',dict(passed=True,**checks,method='Independent SQLite lag/window extraction plus explicit expressions; not a strategy replay'))
    print(json.dumps(dict(passed=True,**checks)))

if __name__=='__main__':main()
