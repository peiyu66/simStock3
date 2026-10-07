#!/usr/bin/env python3
"""Raw close/volume reconstruction for the leading price/volume mechanism."""
import collections as C
import math
import numpy as np
import add_delay_p01 as p
import add_delay_p03 as a

def rounding(v):return math.copysign(math.floor(abs(v)+.5),v)

def main():
    assert not(a.O/'raw-price-volume-audit.json').exists()
    ids=p.read(p.O/'identities.json');values={};checks=C.Counter();ties=[]
    wanted=set()
    for part in ('discovery','later'):
        for k in a.read(a.P/(part+'-keys.json')):wanted.add(tuple(k[x] for x in ('sample','window','stock','date')))
    for sample in 'CD':
        for w,(filename,_,_) in enumerate(p.WINDOWS,1):
            with p.db(p.R/ids[sample]['report']/filename) as db:
                for st in db.execute('select * from ZSTOCK'):
                    sid=st['ZSID'];raw=[dict(r) for r in db.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],))]
                    eligible=[];vlookup={};vcalc={}
                    for n,r in enumerate(raw):
                        if r['ZDATASOURCE']=='TWSE' and math.isfinite(r['ZVOLUMECLOSE']) and r['ZVOLUMECLOSE']>=0:
                            eligible.append(n);vlookup[n]=len(eligible)-1
                    def ma(n):
                        rs=raw[max(0,n-19):n+1];average=sum(r['ZPRICECLOSE'] for r in rs)/len(rs);price=raw[n]['ZPRICECLOSE']
                        stored_average=raw[n]['ZTMA20']
                        assert math.isclose(average,stored_average,rel_tol=1e-12,abs_tol=1e-12)
                        raw_scaled=10000*(price-average)/price
                        expected=rounding(10000*(price-stored_average)/price)/100
                        assert expected==raw[n]['ZTMA20DIFF'],(sid,n,expected,raw[n]['ZTMA20DIFF'])
                        if rounding(raw_scaled)/100!=expected:
                            assert abs(abs(raw_scaled)%1-.5)<1e-9
                            ties.append(dict(sample=sample,window=w,stock=sid,date=p.day(raw[n]['ZDATETIME']),field='MA20',rawAverage=average,storedAverage=stored_average,rawRounded=rounding(raw_scaled)/100,storedRounded=expected))
                        return expected
                    def vol(n):
                        if n not in vcalc:
                            j=vlookup[n];ns=list(reversed(eligible[max(0,j-59):j+1]));mean=sum(raw[k]['ZVOLUMECLOSE'] for k in ns)/len(ns);v=raw[n]['ZVOLUMECLOSE']
                            stored_mean=raw[n]['ZVMA60'];assert math.isclose(mean,stored_mean,rel_tol=1e-12,abs_tol=1e-12)
                            expected=rounding(10000*(v-stored_mean)/v)/100 if v else 0
                            assert expected==raw[n]['ZVMA60DIFF'],(sid,n,expected,raw[n]['ZVMA60DIFF'])
                            if v and rounding(10000*(v-mean)/v)/100!=expected:
                                assert abs(abs(10000*(v-mean)/v)%1-.5)<1e-9
                                ties.append(dict(sample=sample,window=w,stock=sid,date=p.day(raw[n]['ZDATETIME']),field='volumeMA60',rawAverage=mean,storedAverage=stored_mean))
                            vcalc[n]=expected;checks['rawVolumeMeanAndDifference']+=1
                        return vcalc[n]
                    for n,r in enumerate(raw):
                        key=(sample,w,sid,p.day(r['ZDATETIME']))
                        if key not in wanted:continue
                        assert n>0;delta=ma(n)-ma(n-1);j=vlookup[n]
                        minimum=min(vol(k) for k in eligible[max(0,j-8):j+1]);assert minimum==r['ZVMA60DIFFMIN9']
                        values[key]=(delta,minimum);checks['rawMA20Differences']+=2;checks['nineVolumeObservationMinimum']+=1
    cat=a.read(a.P/'feature-catalog.json');index={c['name']:i for i,c in enumerate(cat)}
    for part in ('discovery','later'):
        X=np.load(a.P/(part+'.npz'))['X'];keys=a.read(a.P/(part+'-keys.json'))
        for row,k in zip(X,keys):
            vals=values[tuple(k[x] for x in ('sample','window','stock','date'))]
            for name,v in zip(('delta_ma20_diff','vMa60DiffMin9'),vals):
                if math.isfinite(row[index[name]]):assert row[index[name]]==v;checks['matrixVersusRaw']+=1
    for rel,h in p.HASH.items():assert p.sha(p.R/rel)==h
    a.save(a.O/'raw-price-volume-audit.json',dict(passed=True,distinctDates=len(values),checks=dict(checks),
        formula='MA20 difference=round(10000*(close-MA20)/close)/100; delta=current-prior. Volume difference uses current volume denominator, 60 eligible TWSE observations, recent 9 eligible minimum.',
        timing='Only current/prior raw official observations; no simulated post-ADD value or future return',
        roundingRecovery='Raw average independently agrees at 1e-12 tolerance. Formal difference is recomputed from persisted average; differences from Python raw accumulation allowed only at explicit 0.005-percent midpoint ties. Research always uses exact stored T values.',
        floatingPointMidpointTies=ties,sourceHashes=p.HASH,scriptSHA256=a.sha(__file__)),a.Guard())
    print(dict(passed=True,checks=dict(checks),midpointTies=len(ties)))

if __name__=='__main__':main()
