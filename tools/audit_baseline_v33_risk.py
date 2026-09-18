"""Daily cash conservation and path/capital summary for immutable replay stores."""
import math
from collections import defaultdict
from audit_baseline_v33_market import connect

def audit_store(path):
    summary={}
    with connect(path) as db:
        for stock in db.execute('SELECT * FROM ZSTOCK ORDER BY ZSID'):
            sid=stock['ZSID']; rows=list(db.execute('SELECT * FROM ZTRADE WHERE ZSTOCK=? ORDER BY ZDATETIME',(stock['Z_PK'],)))
            base=stock['ZSIMMONEYBASE']*10000
            checked=0; occupied=0.; loss_days=0; float_loss_days=0.; long_rounds=0
            peak_cost=0.; max_days=0.; max_invest=0.; realized=0.; prev=None
            for r in rows:
                if r['ZSIMRULE']=='_': prev=r; continue
                qty=r['ZSIMQTYBUY']; sold=r['ZSIMQTYSELL']; price=r['ZPRICECLOSE']
                def rnd(x):return math.floor(x+0.5)
                buy=0 if qty==0 else rnd(price*qty*1000)+max(20,rnd(price*qty*1000*0.001425))
                sell=0 if sold==0 else price*sold*1000-max(20,rnd(price*sold*1000*0.001425))-rnd(price*sold*1000*0.003)
                if prev is not None:
                    before=base if prev['ZSIMRULE']=='_' else prev['ZSIMAMTBALANCE']
                    invested=r['ZSIMINVESTADDED']+r['ZSIMINVESTBYUSER']
                    expected=before+base*invested-buy+sell
                    assert abs(expected-r['ZSIMAMTBALANCE'])<0.011,(sid,r['ZDATETIME'],'cash',expected,r['ZSIMAMTBALANCE'])
                    expected_qty=(0 if prev['ZSIMQTYSELL']>0 or prev['ZSIMRULE']=='_' else prev['ZSIMQTYINVENTORY'])+qty-sold
                    assert abs(expected_qty-r['ZSIMQTYINVENTORY'])<1e-8,(sid,r['ZDATETIME'],'inventory')
                    checked+=1
                cost=r['ZSIMAMTCOST']; profit=r['ZSIMAMTPROFIT']
                if r['ZSIMQTYINVENTORY']>0:
                    occupied+=cost
                    if profit<0:loss_days+=1;float_loss_days-=profit
                if sold>0:
                    realized+=profit
                    long_rounds+=int(r['ZSIMDAYS']>=180)
                peak_cost=max(peak_cost,cost);max_days=max(max_days,r['ZSIMDAYS']);max_invest=max(max_invest,r['ZSIMINVESTTIMES']);prev=r
            summary[sid]=dict(name=stock['ZSNAME'],dailyChecks=checked,peakCost=peak_cost,maxHoldingDays=max_days,maxInvestTimes=max_invest,
                occupiedCostTradingDays=occupied,lossTradingDays=loss_days,floatingLossTradingDays=float_loss_days,closed180DayRounds=long_rounds,
                realizedProfit=realized,endingFloatingProfit=rows[-1]['ZSIMAMTPROFIT'] if rows[-1]['ZSIMQTYINVENTORY']>0 else 0,
                moneyLacked=bool(stock['ZSIMMONEYLACKED']),exceed=stock['ZSIMINVESTEXCEED'])
    return summary
