"""Independently reconstruct all five same-day market rule votes on v33 paths."""
import csv
import datetime as dt
import sqlite3
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def connect(path):
    db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    return db

def preview(prev, level, days):
    # Recorder EMA is yesterday's state; production takes one tentative update
    # from the persisted previous state before making today's decisions.
    if days <= 0: return 0,0
    fast,slow,count=prev['ZSIMFITFAST'],prev['ZSIMFITSLOW'],prev['ZSIMFITOBSERVATIONCOUNT']
    if count==0 and fast is None and slow is None: trend=0; count=1
    elif count>0 and fast is not None and slow is not None:
        trend=(fast+2/21*(level-fast))-(slow+2/126*(level-slow));count+=1
    else:return 0,0
    phase=prev['ZSIMFITTRENDPHASERAW'];extreme=prev['ZSIMFITTRENDPHASEEXTREME'];old=prev['ZSIMFITTREND']
    if trend>0.611888:
        if phase not in (4,8,9) or extreme is None:return 8,count
        if phase==9:return (8 if trend>extreme else 9),count
        return (9 if trend<max(extreme,trend)-0.3 else 8),count
    if trend < -0.611888:
        if phase not in (5,10,11) or extreme is None:return 10,count
        if phase==11:return (10 if trend<extreme or (old is not None and trend<old-0.3) else 11),count
        return (11 if trend>min(extreme,trend)+0.3 else 10),count
    if abs(trend)<0.3:return 1,count
    if trend>=0.3:return (6 if phase in (4,8,9,6) else 2),count
    return (7 if phase in (5,10,11,7) else 3),count


def market_audit(base_dir, fixed_dir):
    def csv_rows(path):
        with path.open() as f:
            return {int(r['date'].replace('-', '')): r for r in csv.DictReader(f)}
    market = csv_rows(ROOT / 'exports/market-data/taiex/research/mkt-pp-p1-taiex-price-path-f712b360c322/market-price-path.csv')
    daily = csv_rows(ROOT / 'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af/market-daily.csv')
    # Independently recompute inclusive 9-session extrema from frozen raw OHLC.
    days = sorted(daily)
    for i, day in enumerate(days):
        market[day]['high9'] = max(float(daily[d]['high']) for d in days[max(0,i-8):i+1])
        market[day]['low9'] = min(float(daily[d]['low']) for d in days[max(0,i-8):i+1])
        market[day]['high'] = float(daily[day]['high'])
        market[day]['low'] = float(daily[day]['low'])
    observations = {}
    for start,name in [(20170722,'browse.store'),(20200722,'period-20200722.store'),(20230722,'period-20230722.store')]:
        with connect(fixed_dir / name) as db:
            prev, boundary = {}, {}
            for row in db.execute('SELECT s.ZSID,t.* FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK ORDER BY s.ZSID,t.ZDATETIME'):
                r=dict(row); sid=r['ZSID']
                date=int((dt.datetime(2001,1,1,tzinfo=dt.timezone.utc)+dt.timedelta(seconds=r['ZDATETIME'],hours=8)).strftime('%Y%m%d'))
                observations[start,sid,date]=(r,prev.get(sid),boundary.get(sid))
                phase=r['ZSIMFITTRENDPHASERAW']
                if phase == 3: boundary[sid]='warning'
                elif phase in (5,10,11): boundary[sid]='confirmed'
                prev[sid]=r
    counts=Counter(); positive=Counter()
    with connect(base_dir / 'decisions.sqlite') as db:
        votes={}
        for row in db.execute('SELECT * FROM event_vote_lookup'):
            votes.setdefault(row['event_id'],{})[row['rule_id']]=row['contribution']
        query='''SELECT e.*,w.start_date,s.stock_id,f.fit_trend_phase,f.fit_observation_count,f.fit_level,f.fit_evidence_days
                 FROM decision_events e JOIN windows w USING(window_id) JOIN stocks s USING(stock_key)
                 JOIN event_strategy_fit_observations ef USING(event_id)
                 JOIN strategy_fit_observations f USING(observation_id) WHERE e.phase IN (1,2,3)'''
        for e in db.execute(query):
            date=e['trade_date']; r,prev,boundary=observations[e['start_date'],e['stock_id'],date]
            assert prev is not None
            m=market.get(date); phase=int(m['phase_raw']) if m else None
            high9=bool(m and m['high']==m['high9']); low9=bool(m and m['low']==m['low9'])
            g=e['grade']; p=r['ZTPRICEPATHPHASERAW']
            f,count=preview(prev,e['fit_level'],e['fit_evidence_days'])
            warm=count>=125
            v=votes.get(e['event_id'],{})
            expected={}
            if e['phase']==1:
                threshold=-0.5 if g<=-1 else 0
                hp03=r['ZTMA60DIFF']>threshold and r['ZTMA20DIFF']>threshold
                suppressed=phase==3 and g!=0 and warm and f==9 and p in (4,5)
                expected['H-P03a']=(0.5 if g==-3 else 1.0) if hp03 and not suppressed else 0.0
                expected['H-P04']=int(prev['ZVZ125']>(2 if g<=-1 else 1.5) and not(g>=1 and f!=1 and phase!=2 and high9))
            elif e['phase']==2:
                eligible=g in (-1,1) or (g==-2 and e['inventory_before']>0 and p!=1 and high9)
                expected['L-P10']=int(eligible and warm and f not in (3,5,10,11) and boundary=='confirmed')
            else:
                expected['S-P08']=int(phase==3 and p==3 and g>=2)
                matched=r['ZTMA60DIFF']==r['ZTMA60DIFFMIN9'] or r['ZTMA20DIFF']==r['ZTMA20DIFFMIN9']
                expected['S-N01c']=-int(not matched and g!=0 and g<3 and not(p==3 and g>=1) and low9)
            for rule,value in expected.items():
                assert v.get(rule,0)==value,(e['stock_id'],date,e['start_date'],rule,v.get(rule,0),value)
                counts[rule]+=1; positive[rule]+=int(value!=0)
    return dict(checked=dict(counts),nonzero=dict(positive),sameDay=True,inclusiveNineSessions=True)
