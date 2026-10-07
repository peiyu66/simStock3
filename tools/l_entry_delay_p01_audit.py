#!/usr/bin/env python3
"""Independent SQL window audit of LD-P01 events and ten-session prices."""
import collections
import json
import math
import sqlite3
from pathlib import Path
import l_entry_delay_p01 as p

def audit():
    expected=json.loads((p.O/'entry-events.json').read_text())
    seen=set()
    counts=collections.Counter()
    for sample in 'CD':
        report=p.R/'exports/backtest-reports'/f'baseline-{sample.lower()}-v37-s49-sell-delay-f03-r1-t3s61-9y-fixed3y-600w-20261001'
        for w,(filename,start,end) in enumerate([
            ('browse.store',20170722,20200722),('period-20200722.store',20200722,20230722),
            ('period-20230722.store',20230722,20260722)],1):
            path=report/filename
            assert not Path(str(path)+'-wal').exists() or Path(str(path)+'-wal').stat().st_size==0
            with sqlite3.connect(path.as_uri()+'?mode=ro&immutable=1',uri=True) as c:
                c.row_factory=sqlite3.Row
                query='''WITH dated AS (
                  SELECT t.*,s.ZSID AS sid,
                    CAST(strftime('%Y%m%d', t.ZDATETIME+978307200,'unixepoch','+8 hours') AS INTEGER) AS d
                  FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK
                ), framed AS (
                  SELECT *, lag(ZSIMQTYINVENTORY) OVER (PARTITION BY sid ORDER BY d) AS previous_inventory,
                    count(*) OVER (PARTITION BY sid ORDER BY d ROWS BETWEEN 1 FOLLOWING AND 10 FOLLOWING) AS future_count,
                    min(ZPRICECLOSE) OVER (PARTITION BY sid ORDER BY d ROWS BETWEEN 1 FOLLOWING AND 10 FOLLOWING) AS future_min
                  FROM dated WHERE d <= ?
                ) SELECT * FROM framed WHERE d >= ? AND ZSIMQTYBUY>0 AND ZSIMRULEBUY='L'
                  AND previous_inventory=0 AND coalesce(ZSIMREVERSED,'')='' AND coalesce(ZSIMINVESTBYUSER,0)=0'''
                observed={ (sample,w,r['sid'],r['d']):dict(r) for r in c.execute(query,(end,start)) }
                target=[e for e in expected if e['sample']==sample and e['window']==w]
                assert set(observed)=={(sample,w,e['stock'],e['date'])for e in target}
                for e in target:
                    key=(sample,w,e['stock'],e['date']);r=observed[key];seen.add(key)
                    assert r['future_count']==e['futureAvailableDays']
                    assert r['future_min']==e['minimumClose']
                    assert bool(r['future_min'] is not None and r['future_min']<r['ZPRICECLOSE'])==e['hasLowerPrice']
                    assert math.isclose(r['ZPRICECLOSE'],e['price'],abs_tol=1e-12)
                    # Separate date-limited SQL query checks earliest lower day and all tied minima.
                    dates_prices=list(c.execute('''SELECT CAST(strftime('%Y%m%d',ZDATETIME+978307200,'unixepoch','+8 hours') AS INTEGER),ZPRICECLOSE
                       FROM ZTRADE WHERE ZSTOCK=? AND ZDATETIME>? AND CAST(strftime('%Y%m%d',ZDATETIME+978307200,'unixepoch','+8 hours') AS INTEGER)<=?
                       ORDER BY ZDATETIME LIMIT 10''',(r['ZSTOCK'],r['ZDATETIME'],end)))
                    first=next((i for i,(_,v)in enumerate(dates_prices,1)if v<r['ZPRICECLOSE']),None)
                    assert first==e['firstLowerDay']
                    assert [d for d,v in dates_prices if v==r['future_min']]==e['minimumDates']
                    counts['eventsVerified']+=1
                    counts['futureRowsVerified']+=len(dates_prices)
    assert len(seen)==len(expected)
    hashes=json.loads((p.O/'source-hashes.json').read_text())
    for path,digest in hashes.items():assert p.sha(p.R/path)==digest,path
    catalog=json.loads((p.O/'feature-catalog.json').read_text())
    coverage=json.loads((p.O/'source-coverage.json').read_text())
    universe=json.loads((p.O/'source-universe.json').read_text())
    assert len({f['name']for f in catalog})==len(catalog)
    assert len({x['id']for x in coverage})==len(coverage)
    covered={(x['scope'],x['field'])for x in coverage if x['presentInCurrentSource']}
    missing={(scope,f)for scope,fields in universe.items()for f in fields}-covered
    assert not missing,missing
    result=dict(status='passed',method='Independent SQLite window frames and date-limited price queries; no strategy replay',
                **counts,sourceHashesUnchanged=len(hashes),sourceLocationsCovered=len(covered),
                repairs=['Directory-vs-SQLite file probe corrected before analysis',
                         'Technical observations intentionally only L scores4..6; all 3 score7/8 entries retained',
                         'price_phase/market_phase source resolved from field-contract, not optional old source key'])
    p.save('audit.json',result)
    print(json.dumps(result,ensure_ascii=False))

if __name__=='__main__':audit()
