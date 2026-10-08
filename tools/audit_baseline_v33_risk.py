"""Daily cash conservation and path/capital summary for immutable replay stores."""
import math
import json
import datetime as dt
from audit_baseline_v33_market import connect

def validate_settlement(r, prev, base, invested, buy):
    """Signed residual after returning additional principal is not spendable cash.

    Reject an unfunded purchase or an unexplained negative balance. Accept only
    the existing post-sale principal return and its unchanged, empty aftermath.
    """
    if prev is None:
        assert r['ZSIMAMTBALANCE'] >= -0.01
        return False
    before = base if prev['ZSIMRULE'] == '_' else prev['ZSIMAMTBALANCE']
    if buy > 0:
        assert before + base * invested >= buy - 0.011, 'unfunded purchase'
    if r['ZSIMAMTBALANCE'] >= -0.01:
        return False
    assert r['ZSIMQTYBUY'] == r['ZSIMQTYSELL'] == r['ZSIMQTYINVENTORY'] == 0, 'negative cash with trade or inventory'
    assert r['ZSIMAMTCOST'] == r['ZSIMAMTPROFIT'] == 0, 'negative settlement has position value'
    assert r['ZSIMINVESTBYUSER'] == 0 and r['ZSIMINVESTTIMES'] == 1
    if before >= -0.01:
        assert prev['ZSIMQTYSELL'] > 0 and invested == 1 - prev['ZSIMINVESTTIMES'] < 0, 'unexplained negative settlement'
    else:
        assert invested == 0 and abs(r['ZSIMAMTBALANCE'] - before) < 0.011, 'negative settlement changed without funding'
    assert abs(r['ZROLLAMTPROFIT'] - (r['ZSIMAMTBALANCE'] - base)) < 0.011, 'settlement loss not preserved'
    return True

def audit_store(path, end=None, expected_data_rules=None, expected_warning_format=5):
    summary={}
    with connect(path) as db:
        for stock in db.execute('SELECT * FROM ZSTOCK ORDER BY ZSID'):
            sid=stock['ZSID']; rows=list(db.execute('SELECT * FROM ZTRADE WHERE ZSTOCK=? ORDER BY ZDATETIME',(stock['Z_PK'],)))
            if end is not None:
                # Formal periodEnd is local midnight. Daily observations occur
                # later that day, so its raw rows remain outside the replay.
                rows=[r for r in rows if int((dt.datetime(2001,1,1)+dt.timedelta(seconds=r['ZDATETIME'],hours=8)).strftime('%Y%m%d'))<end]
            base=stock['ZSIMMONEYBASE']*10000
            checked=0; warning_checked=0; occupied=0.; loss_days=0; float_loss_days=0.; long_rounds=0
            peak_cost=0.; max_days=0.; max_invest=0.; realized=0.; prev=None
            negative_days=0; minimum_settlement=0.; first_negative=None
            for r in rows:
                if r['ZSIMRULE']=='_': prev=r; continue
                if expected_data_rules is not None:
                    payload=json.loads(r['ZSIMANNUALWARNINGDATA'])
                    assert payload['dataRules']==expected_data_rules and payload['formatVersion']==expected_warning_format,(sid,r['ZDATETIME'],'warning version')
                    assert payload['configuration']['budget']==600 and payload['configuration']['additions']==2
                    warning_checked+=1
                qty=r['ZSIMQTYBUY']; sold=r['ZSIMQTYSELL']; price=r['ZPRICECLOSE']
                def rnd(x):return math.floor(x+0.5)
                buy=0 if qty==0 else rnd(price*qty*1000)+max(20,rnd(price*qty*1000*0.001425))
                sell=0 if sold==0 else price*sold*1000-max(20,rnd(price*sold*1000*0.001425))-rnd(price*sold*1000*0.003)
                invested=r['ZSIMINVESTADDED']+r['ZSIMINVESTBYUSER']
                if prev is not None:
                    before=base if prev['ZSIMRULE']=='_' else prev['ZSIMAMTBALANCE']
                    expected=before+base*invested-buy+sell
                    assert abs(expected-r['ZSIMAMTBALANCE'])<0.011,(sid,r['ZDATETIME'],'cash',expected,r['ZSIMAMTBALANCE'])
                    expected_qty=(0 if prev['ZSIMQTYSELL']>0 or prev['ZSIMRULE']=='_' else prev['ZSIMQTYINVENTORY'])+qty-sold
                    assert abs(expected_qty-r['ZSIMQTYINVENTORY'])<1e-8,(sid,r['ZDATETIME'],'inventory')
                    checked+=1
                if validate_settlement(r, prev, base, invested, buy):
                    negative_days+=1
                    minimum_settlement=min(minimum_settlement,r['ZSIMAMTBALANCE'])
                    if first_negative is None:
                        first_negative=(dt.datetime(2001,1,1)+dt.timedelta(seconds=r['ZDATETIME'],hours=8)).strftime('%Y/%m/%d')
                cost=r['ZSIMAMTCOST']; profit=r['ZSIMAMTPROFIT']
                if r['ZSIMQTYINVENTORY']>0:
                    occupied+=cost
                    if profit<0:loss_days+=1;float_loss_days-=profit
                if sold>0:
                    realized+=profit
                    long_rounds+=int(r['ZSIMDAYS']>=180)
                peak_cost=max(peak_cost,cost);max_days=max(max_days,r['ZSIMDAYS']);max_invest=max(max_invest,r['ZSIMINVESTTIMES']);prev=r
            summary[sid]=dict(name=stock['ZSNAME'],dailyChecks=checked,warningChecks=warning_checked,
                negativeSettlementDays=negative_days,minimumSettlement=minimum_settlement,firstNegativeSettlement=first_negative,
                peakCost=peak_cost,maxHoldingDays=max_days,maxInvestTimes=max_invest,
                occupiedCostTradingDays=occupied,lossTradingDays=loss_days,floatingLossTradingDays=float_loss_days,closed180DayRounds=long_rounds,
                realizedProfit=realized,endingFloatingProfit=rows[-1]['ZSIMAMTPROFIT'] if rows[-1]['ZSIMQTYINVENTORY']>0 else 0,
                moneyLacked=bool(stock['ZSIMMONEYLACKED']),exceed=stock['ZSIMINVESTEXCEED'])
    return summary

if __name__ == '__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('store')
    parser.add_argument('--end',type=int,required=True)
    args=parser.parse_args()
    result=audit_store(args.store,args.end)
    print(json.dumps({'cashAndInventoryConservation':True,'noUnfundedPurchase':True,
        'negativeSettlementDays':sum(r['negativeSettlementDays'] for r in result.values())}))
