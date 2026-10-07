#!/usr/bin/env python3
"""Independent SQL price/calendar audit and original-exit annotations; read only."""
import collections, csv, json, sqlite3
from pathlib import Path
import l_entry_delay_p02 as p

def main():
    assert not(p.O/'completion.json').exists()
    identities=p.read(p.P/'identities.json')
    events=p.read(p.P/'entry-events.json')
    keys=sum([p.read(p.O/(label+'-keys.json'))for label in ('discovery','later')],[])
    market={int(r['date'].replace('-',''))for r in csv.DictReader((p.h.MARKET/'market-daily.csv').open())}
    exits=[];checked=0;gaps=0
    for sample in 'CD':
        for w,filename in enumerate(['browse.store','period-20200722.store','period-20230722.store'],1):
            path=p.R/identities[sample]['report']/filename
            assert not Path(str(path)+'-wal').exists()or Path(str(path)+'-wal').stat().st_size==0
            with sqlite3.connect(path.as_uri()+'?mode=ro&immutable=1',uri=True)as db:
                db.row_factory=sqlite3.Row
                rows=list(db.execute('''SELECT s.ZSID sid,t.ZPRICECLOSE price,t.ZVOLUMECLOSE volume,t.ZSIMQTYSELL sold,
                    CAST(strftime('%Y%m%d',t.ZDATETIME+978307200,'unixepoch','+8 hours') AS INTEGER) day,
                    lag(CAST(strftime('%Y%m%d',t.ZDATETIME+978307200,'unixepoch','+8 hours') AS INTEGER))
                    OVER(PARTITION BY s.ZSID ORDER BY t.ZDATETIME) prior_day
                    FROM ZTRADE t JOIN ZSTOCK s ON t.ZSTOCK=s.Z_PK'''))
                lookup={(r['sid'],r['day']):r for r in rows}
                for k in keys:
                    if (k['sample'],k['window'])!=(sample,w):continue
                    r=lookup[(k['stock'],k['date'])]
                    assert (r['price'],r['volume'],r['prior_day'])==(k['close'],k['volume'],k['previousDate'])
                    missing=sorted(d for d in market if r['prior_day']<d<r['day'])
                    assert missing==k['calendarGapDates']
                    checked+=1;gaps+=bool(missing)
                for e in events:
                    if (e['sample'],e['window'])!=(sample,w):continue
                    exitday=min((r['day']for r in rows if r['sid']==e['stock']and r['day']>e['date']and r['sold']>0),default=None)
                    assert exitday==e['originalExitDate']
                    exits.append(dict(sample=sample,window=w,stock=e['stock'],anchor=e['date'],originalExitDate=exitday,
                        futureDatesOnOrAfterOriginalExit=[d for d in e['futureDates']if exitday is not None and d>=exitday],
                        minimaOnOrAfterOriginalExit=[d for d in e['minimumDates']if exitday is not None and d>=exitday],
                        firstLowerAfterOriginalExit=e['firstLowerAfterOriginalExit']))
    assert checked==652
    same_stock=[]
    for i,a in enumerate(events):
        for b in events[i+1:]:
            if (a['sample'],a['window'],a['stock'])==(b['sample'],b['window'],b['stock']):
                overlap=sorted(set([a['date'],*a['futureDates']])&set([b['date'],*b['futureDates']]))
                if overlap:same_stock.append(dict(stock=a['stock'],anchors=[a['date'],b['date']],dates=overlap))
    counts=collections.Counter(e['date']for e in events)
    result=dict(passed=True,method='Independent SQLite date conversion, lag and price/volume; original sell dates',
        priceRowsVerified=checked,selectedRowsWithCalendarGaps=gaps,events=exits,
        eventsReachingOriginalExit=sum(bool(e['futureDatesOnOrAfterOriginalExit'])for e in exits),
        minimaReachingOriginalExit=sum(bool(e['minimaOnOrAfterOriginalExit'])for e in exits),
        overlappingSameStockEpisodes=same_stock,uniqueAnchorDates=len(counts),maxSameDateAnchors=max(counts.values()))
    for path,digest in p.read(p.O/'source-hashes.json').items():assert p.p1.sha(p.R/path)==digest,path
    result['auditToolSHA256']=p.p1.sha(Path(__file__))
    p.save('timing-audit.json',result)
    print(json.dumps({k:v for k,v in result.items()if k!='events'},ensure_ascii=False))

if __name__=='__main__':main()
