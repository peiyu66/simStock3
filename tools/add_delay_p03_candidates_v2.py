#!/usr/bin/env python3
"""Discovery-only navigation freeze, then explicit observed-price candidate cards.

Gate contract v2: all 2,097,727 formulas remain in the original binary archive;
 separate archives correct only fixed-input inapplicability. Four navigation cards per
source are not a claim of formula-pool exhaustion or an adoption threshold.
"""
import argparse
import collections as C
import csv
import functools
import json
import math
import time
import add_delay_p03 as a
import add_delay_p03_audit as audit
from add_delay_p03_gate_contract import OUT, archive_records, effective_result, effective_oracle

def masks(data,key):
    return [sum(1<<i for i,o in enumerate(data['ops']) if key(o)==value) for value in sorted({key(o) for o in data['ops']})]

def freeze():
    assert not(OUT/'shortlist-freeze.json').exists()
    assert a.read(OUT/'coverage-audit.json')['passed']
    guard=a.Guard();guard.check();guard.watch();data=a.inputs();atoms=data['atoms']
    good=data['lower'];bad=data['eligible']&~good;unknown=data['quality_unknown']
    cell=masks(data,lambda o:(o['sample'],o['window']));stocks=masks(data,lambda o:o['stock']);dates=masks(data,lambda o:o['anchor'])
    @functools.lru_cache(maxsize=65536)
    def stats(mask,valid):
        pos=mask&good;tp=pos.bit_count();fp=(mask&bad).bit_count();u=(mask&unknown).bit_count()
        cells=[(pos&m).bit_count() for m in cell]
        return (tp,fp,u,tp/(tp+fp) if tp+fp else -1,sum(v>0 for v in cells),min(cells),sum(bool(pos&m) for m in stocks),sum(bool(pos&m) for m in dates),valid.bit_count())
    def ranks(row):
        i,j,source,s,r=row;tp,fp,u,precision,cells,mincell,st,dt,valid=s;lo,hi,eq,wait,unk,qu=r
        complexity=(2 if atoms[i]['op']=='between' else 1)+(2 if atoms[j]['op']=='between' else 1)
        tail=(-fp,-u,valid,-complexity,-i,-j)
        label=(precision,cells,tp,st,dt,*tail);breadth=(tp,cells,precision,st,dt,*tail)
        if 'S' in source:
            return {'label-precision':label,'label-breadth':breadth,'cell-coverage':(cells,precision,tp,st,dt,*tail),'cell-balance':(mincell,tp,precision,cells,st,dt,*tail)}
        denom=lo+hi+eq+wait
        purity=lo/denom if denom else -1
        return {'release-purity':(purity,lo,-hi,-wait,cells,st,*tail),'release-breadth':(lo,purity,-hi,-wait,cells,st,*tail),'label-precision':label,'label-breadth':breadth}
    leaders={};totals=C.Counter();positive=C.Counter();hist=C.Counter()
    for batch in ('A','B'):
        for i,j,mb,vb,*release in archive_records(a.O/('batch-'+batch)/'pairs.bin'):
            source=a.source_group(atoms[i],atoms[j]);m=int.from_bytes(mb,'little');v=int.from_bytes(vb,'little');s=stats(m,v)
            totals[source]+=1;hist[(source,s[0],s[1])]+=1
            if s[0]==0:continue # no observed lower-price evidence; archive still retains it
            positive[source]+=1;row=(i,j,source,s,tuple(release));family=(source,*sorted((atoms[i]['parent'],atoms[j]['parent'])))
            current=leaders.setdefault(family,{})
            for kind,rank in ranks(row).items():
                if kind.startswith('release-') and release[0]==0:continue
                if kind not in current or rank>current[kind][0]:current[kind]=(rank,row)
            if sum(totals.values())%200000==0:
                guard.check();print(json.dumps(dict(organized=sum(totals.values()),parentFamilies=len(leaders),seconds=round(guard.seconds(),2))),flush=True)
    # Compact, complete parent-family navigation; no million-row JSON expansion.
    path=OUT/'family-leaders.csv';tmp=path.with_suffix('.csv.tmp')
    with tmp.open('w') as f:
        w=csv.writer(f);w.writerow(['source','parent1','parent2','ranking','atom_i','atom_j','label_lower','label_no_lower','label_unknown','precision','positive_cells','minimum_cell_lower','positive_stocks','positive_dates','valid','release_lower','release_higher','release_equal','not_released','own_or_input_unknown','quality_unknown'])
        for n,(family,options) in enumerate(sorted(leaders.items())):
            for kind,(_,row) in sorted(options.items()):w.writerow([*family,kind,row[0],row[1],*row[3],*row[4]])
            if n%1000==0:guard.check(65536);f.flush()
    guard.check();tmp.replace(path)
    cards=[]
    for source in ('T','S','M','TS','TM','SM'):
        used=set()
        kinds=['label-precision','label-breadth','cell-coverage','cell-balance'] if 'S' in source else ['release-purity','release-breadth','label-precision','label-breadth']
        for kind in kinds:
            options=[(v[kind][0],family,v[kind][1]) for family,v in leaders.items() if family[0]==source and family not in used and kind in v]
            if not options:continue
            rank,family,row=max(options);used.add(family);i,j,_,s,rel=row
            cards.append(dict(id='AD-J'+str(len(cards)+1).zfill(2),source=source,selection=kind,parents=list(family[1:]),atoms=[i,j],
                formula=[{k:atoms[n][k] for k in ('id','name','parent','group','op','value')} for n in (i,j)],discoveryStats=dict(zip(['lower','noLower','qualityUnknown','precision','positiveCells','minimumCellLower','positiveStocks','positiveDates','valid'],s)),
                discoveryRelease=dict(zip(['lower','higher','equal','notReleased','ownOrInputUnknown','qualityUnknown'],rel))))
    guard.finish()
    a.save(OUT/'search-distribution.json',dict(pairCounts=dict(totals),pairsWithAnyQualifiedLower=dict(positive),parentFamilies=len(leaders),familyLeadersSHA256=a.sha(path),labelHistogram=[dict(source=s,lower=t,noLower=f,count=n) for (s,t,f),n in sorted(hist.items())],resource=dict(seconds=guard.seconds(),peakRSSBytes=guard.peak_rss,peakArtifactBytes=guard.peak_disk)),guard)
    a.save(OUT/'shortlist-freeze.json',dict(status='frozen-before-later-evaluation',cards=cards,navigationOnly=True,allPairsRetained=True,
         method=a.read(a.O/'protocol.json')['method'],rankDefinitions='tools/add_delay_p03_candidates_v2.py:ranks; release purity denominator excludes unknowns but includes equal and ten-day nonrelease; S uses only retrospective labels',
         candidateScriptSHA256=a.sha(__file__),coverageAuditSHA256=a.sha(OUT/'coverage-audit.json'),pairArchives={b:a.sha(a.O/('batch-'+b)/'pairs.bin') for b in ('A','B')},
         sources=a.verify_sources(),frozenAt=time.time()),guard)
    print(json.dumps(dict(status='frozen',cards=len(cards),families=len(leaders),seconds=guard.seconds(),peakRSSBytes=guard.peak_rss)))

def evaluate():
    assert not(OUT/'candidate-cards.json').exists()
    freeze=a.read(OUT/'shortlist-freeze.json');assert freeze['candidateScriptSHA256']==a.sha(__file__)
    guard=a.Guard();guard.check();guard.watch();cards=[];events=[];independent_checks=0
    original={(e['sample'],e['window'],e['stock'],e['date']):e for e in a.read(a.R/'exports/add-delay-p01-20261002/events.json')}
    for part in ('discovery','later'):
        d=a.inputs(part);ind=audit.independent_inputs(part);atoms=d['atoms']
        for card in freeze['cards']:
            i,j=card['atoms'];x,y=atoms[i],atoms[j];mask,valid,releases=effective_result(x,y,d)
            assert releases==effective_oracle(ind['atoms'][i],ind['atoms'][j],mask,ind)
            entries=[]
            for k,(op,label) in enumerate(zip(d['ops'],d['labels'])):
                e=original[(op['sample'],op['window'],op['stock'],op['anchor'])]
                row=dict(candidate=card['id'],partition=part,sample=op['sample'],window=op['window'],stock=op['stock'],name=e['name'],date=op['anchor'],price=e['price'],gateType=e['gateType'],entryRule=e['buy_rule_before'],
                    valid=bool(valid>>k&1),triggered=bool(mask>>k&1),quality=label['reason'],opportunity=label['opportunity'],
                    values={s['name']:None if not math.isfinite(float(d['X'][d['entries'][k],next(jj for jj,c in enumerate(d['cat']) if c['name']==s['name'])])) else float(d['X'][d['entries'][k],next(jj for jj,c in enumerate(d['cat']) if c['name']==s['name'])]) for s in (x,y)},
                    release='not-triggered',releaseOffset=None,releasePrice=None,releaseChangePct=None,lowerBeforeRelease=False,lowerAfterRelease=False,originalExitBeforeRelease=False)
                if row['triggered']:
                    if not label['eligible']:row['release']='quality-unknown'
                    elif 'S' in card['source']:row['release']='own-S-unknown'
                    else:
                        row['release']='no-release-within-ten'
                        for t in range(10):
                            # Fixed T/M inapplicable input does not impose a gate; truth mask is false.
                            if not(x['days'][t][1]>>k&1 and y['days'][t][1]>>k&1):
                                future=e['future'][t];delta=future['changePct'];row.update(release='lower' if delta<0 else 'higher' if delta>0 else 'equal',releaseOffset=t+1,releasePrice=future['price'],releaseChangePct=delta,
                                   lowerBeforeRelease=any(z['price']<e['price'] for z in e['future'][:t]),lowerAfterRelease=any(z['price']<e['price'] for z in e['future'][t+1:]),originalExitBeforeRelease=e['originalExitOffset'] is not None and e['originalExitOffset']<=t+1)
                                break
                entries.append(row);events.append(row);independent_checks+=1
            hit=[e for e in entries if e['triggered']];pos=[e for e in hit if e['opportunity'] is True];no=[e for e in hit if e['opportunity'] is False]
            def summary(rs):
                rs=[e for e in rs if e['triggered']]
                return dict(hits=len(rs),labelLower=sum(e['opportunity'] is True for e in rs),labelNoLower=sum(e['opportunity'] is False for e in rs),qualityUnknown=sum(e['opportunity'] is None for e in rs),release=dict(C.Counter(e['release'] for e in rs)))
            cards.append(dict(id=card['id'],source=card['source'],partition=part,formula=card['formula'],selection=card['selection'],**summary(hit),
                valid=sum(e['valid'] for e in entries),stocks=len({e['stock'] for e in hit}),dates=len({e['date'] for e in hit}),
                byCell={s+str(w):summary([e for e in entries if e['sample']==s and e['window']==w]) for s,w in sorted({(e['sample'],e['window']) for e in entries})},
                byGate={g:summary([e for e in entries if e['gateType']==g]) for g in ('A-T01','A-T02')},
                maxPositiveStockShare=max(C.Counter(e['stock'] for e in pos).values())/len(pos) if pos else None,
                maxPositiveDateShare=max(C.Counter(e['date'] for e in pos).values())/len(pos) if pos else None,
                higherAfterEarlierLow=sum(e['release']=='higher' and e['lowerBeforeRelease'] for e in hit),
                higherBeforeLaterLow=sum(e['release']=='higher' and e['lowerAfterRelease'] for e in hit),
                baselineExitBeforeRelease=sum(e['originalExitBeforeRelease'] for e in hit)))
            guard.check()
    guard.finish()
    a.save(OUT/'candidate-events.json',events,guard);a.save(OUT/'candidate-cards.json',cards,guard)
    for rel,h in freeze['sources'].items():assert a.sha(a.R/rel)==h,rel
    a.save(OUT/'candidate-audit.json',dict(passed=True,selectedCards=len(freeze['cards']),eventChecks=independent_checks,
        independentReleaseChecks=2*len(freeze['cards']),freezeSHA256=a.sha(OUT/'shortlist-freeze.json'),candidateScriptSHA256=a.sha(__file__),
        futureS='Every S-source candidate release remains unknown; not ranked as failure',actualCandidateExecutionMeasured=False,
        laterStatus='Already exposed by pilot; evaluation uses unchanged discovery freeze, never called blind',
        resource=dict(seconds=guard.seconds(),peakRSSBytes=guard.peak_rss,peakArtifactBytes=guard.peak_disk),
        artifacts={n:a.sha(OUT/n) for n in ('candidate-events.json','candidate-cards.json')}),guard)
    for c in cards:print(json.dumps({k:c[k] for k in ('id','source','partition','hits','labelLower','labelNoLower','release')},ensure_ascii=False))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('stage',choices=['freeze','evaluate']);args=p.parse_args()
    freeze() if args.stage=='freeze' else evaluate()
