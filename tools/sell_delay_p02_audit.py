#!/usr/bin/env python3
"""Bounded SD-P02 date/missingness audit; no composite condition evaluation."""
import bisect, collections, json, statistics
import numpy as np
from sell_delay_p02 import R,O,read,save,h

def audit():
    assert not (O/'completion.json').exists()
    market=sorted(h.csvmap(h.MARKET/'market-daily.csv'))
    all_ops=[];all_keys=[];gap_rows={};checks=collections.Counter();feature_stats=[];by_label={}
    cat=read(O/'feature-catalog.json');known={x['name'] for x in read(O/'atoms-no-outcome-ranking.json')}
    for label in ('discovery','later'):
        keys=read(O/f'{label}-keys.json');ops=read(O/f'{label}-opportunities.json');data=np.load(O/f'{label}.npz');X=data['X']
        all_ops+=ops;all_keys+=keys;by_label[label]=(keys,ops)
        for key in keys:
            gap=market[bisect.bisect_right(market,key['previousDate']):bisect.bisect_left(market,key['date'])] if key['previousDate'] else []
            if gap:gap_rows[key['sample'],key['window'],key['stock'],key['date']]=dict(sample=key['sample'],window=key['window'],stock=key['stock'],date=key['date'],previous=key['previousDate'],marketDatesWithoutStockRows=gap,interpretation='No observed stock row; cannot distinguish suspension from missing quote using this data alone')
        for op in ops:
            rows=[keys[i] for i in op['indices']]
            assert all(r['source']=='TWSE' and r['close']>0 and r['volume']>0 and r['marketPresent'] for r in rows)
            if op['completeTen']:
                assert len(rows)==11
                assert op['fullOpportunity']==any(r['close']>rows[0]['close'] for r in rows[1:])
            else:assert op['fullOpportunity'] is None
            assert op['highestDates']==[r['date'] for r in rows[1:] if r['close']==op['highestClose']]
            assert op['firstHigherDate']==next((r['date'] for r in rows[1:] if r['close']>rows[0]['close']),None)
            checks['rawPathOracleChecks']+=1
        # Explicit no-silent-omission disposition for every field, by partition.
        for j,c in enumerate(cat):
            anchors=X[data['anchors'],j];ok=np.isfinite(anchors);unique=np.unique(anchors[ok])
            feature_stats.append(dict(partition=label,name=c['name'],group=c['group'],finite=int(ok.sum()),missing=int((~ok).sum()),distinct=len(unique),searchDisposition=('available atoms' if c['name'] in known else 'no nonconstant predicate in W1/W2; retained in full data'),futureCandidateSUnknown=c['group']=='S'))
    complete=[o for o in all_ops if o['completeTen']];positive=[o for o in complete if o['fullOpportunity']]
    paths=dict(higherThenLower=sum(o['pathTransitions'][:2]==['higher','lower'] for o in complete),lowerThenHigher=sum(o['pathTransitions'][:2]==['lower','higher'] for o in complete),positiveWithInterimBelowOriginal=sum(o['minGainBeforeFirstPeakPct']<0 for o in positive),positiveWithMultipleHigherSegments=sum(len(o['higherSegments'])>1 for o in positive),positiveMedianHigherDays=statistics.median(o['higherDays'] for o in positive),positivePeakDayDistribution=dict(collections.Counter(o['firstPeakOffset'] for o in positive)),tiedHighestDates=sum(len(o['highestDates'])>1 for o in complete))
    missing=sorted(gap_rows.values(),key=lambda x:(x['sample'],x['window'],x['stock'],x['date']))
    # Unknown missing quote versus suspension must not become a success/failure label.
    for label,(keys,ops) in by_label.items():
        for op in ops:
            gap_dates=[keys[i]['date'] for i in op['indices'][1:] if (op['sample'],op['window'],op['stock'],keys[i]['date']) in gap_rows]
            op['calendarGapDates']=gap_dates
            op['qualifiedOpportunity']=op['fullOpportunity'] if op['completeTen'] and not gap_dates else None
            op['qualityStatus']='window-truncated' if not op['completeTen'] else 'calendar-gap-unknown' if gap_dates else 'qualified-observed-horizon'
        save(f'{label}-opportunities.json',ops)
    def qualified(ops):
        usable=[o for o in ops if o['qualifiedOpportunity'] is not None]
        higher=sum(o['qualifiedOpportunity'] for o in usable)
        return dict(total=len(ops),usable=len(usable),higher=higher,noHigher=len(usable)-higher,unknown=len(ops)-len(usable),higherRate=higher/len(usable) if usable else None)
    quality_summary=dict(all=qualified(all_ops),partitions={l:qualified(v[1]) for l,v in by_label.items()},cells={s+str(w):qualified([o for o in all_ops if o['sample']==s and o['window']==w]) for s in 'AB' for w in (1,2,3)},exits={r:qualified([o for o in all_ops if o['exitRoute']==r]) for r in ('profit','recovery','both')},unknownEvents=[dict(sample=o['sample'],window=o['window'],stock=o['stock'],anchor=o['anchor'],reason=o['qualityStatus'],calendarGapDates=o['calendarGapDates']) for o in all_ops if o['qualifiedOpportunity'] is None])
    save('qualified-opportunity-summary.json',quality_summary)
    unique={(k['sample'],k['window'],k['stock'],k['date']):k for k in all_keys}
    save('date-quality-audit.json',dict(passed=True,oracleChecks=dict(checks),uniqueRows=len(unique),positiveVolumeRows=sum(k['volume']>0 for k in unique.values()),sameDayMarketRows=sum(k['marketPresent'] for k in unique.values()),under250PriceRows=[dict(sample=k['sample'],window=k['window'],stock=k['stock'],date=k['date'],priceObservations=k['priceObservations']) for k in unique.values() if k['priceObservations']<250],calendarGaps=missing,paths=paths))
    save('field-dispositions.json',feature_stats)
    # Clear obsolete rule-version text carried only as a formula reference.
    contracts=read(O/'field-contract.json')
    for c in contracts:
        if c.get('formula'):c['formula']=c['formula'].replace('S57','S59')
    save('field-contract.json',contracts)
    print(json.dumps(dict(checks=dict(checks),calendarGaps=len(missing),paths=paths),ensure_ascii=False))

if __name__=='__main__':audit()
