#!/usr/bin/env python3
"""LD-P04: frozen six + exactly 17 predeclared one-cut variants. No replay."""
import collections as C, json
import numpy as np
import l_entry_delay_p03 as prior
from l_entry_delay_p03_check import evaluate

R=prior.R;P=prior.P;PRE=prior.O;O=R/'exports/l-entry-delay-p04-20261001'
read=prior.read;sha=prior.sha
def save(name,value):
    t=O/(name+'.tmp');t.write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n');t.replace(O/name)
def release(states,prices,dates,anchor,complete,has_s=False):
    if has_s:return dict(status='candidate-S-unknown',offset=None,priceClass=None)
    first=next((i for i,s in enumerate(states)if s is False),None)
    unknown_before=any(s is None for s in states[:first+1]if first is not None)if first is not None else any(s is None for s in states)
    if first is None:
        return dict(status='input-unknown'if unknown_before else 'persisted-ten-days'if complete else 'truncated-no-release',offset=None,priceClass=None)
    v=prices[first];return dict(status='first-release-uncertain'if unknown_before else'observed-release',offset=first+1,
        date=dates[first],close=v,priceChangePct=100*(v/anchor-1),priceClass='lower'if v<anchor else'higher'if v>anchor else'equal',
        reactivatedLater=any(s is True for s in states[first+1:]))
def summarize(events):
    hits=[e for e in events if e['trigger']is True];known=[e for e in hits if e['opportunity']is not None]
    return dict(hits=len(hits),lower=sum(e['opportunity']is True for e in hits),noLower=sum(e['opportunity']is False for e in hits),
        censored=sum(e['opportunity']is None for e in hits),unavailable=sum(e['trigger']is None for e in events),
        releaseStatuses=dict(C.Counter(e['release']['status']for e in hits)),
        firstReleasePrices=dict(C.Counter(e['release']['priceClass']for e in known if e['release']['status']=='observed-release')),
        reactivations=sum(e['release'].get('reactivatedLater',False)for e in hits),
        cells={s+str(w):dict(hits=sum(e['sample']==s and e['window']==w for e in hits),
                           lower=sum(e['sample']==s and e['window']==w and e['opportunity']is True for e in hits))for s in 'CD'for w in (1,2,3)})
def main():
    assert not(O/'completion.json').exists()and not(O/'cards.json').exists()
    O.mkdir(parents=True,exist_ok=True)
    done=read(PRE/'completion.json');assert done['status']=='complete'
    protected={**read(PRE/'protected.json'),**done['artifacts'],str((PRE/'completion.json').relative_to(R)):sha(PRE/'completion.json')}
    for f,d in protected.items():assert sha(R/f)==d,f
    protected[str(__file__).removeprefix(str(R)+'/')]=sha(__file__)
    save('protocol.json',dict(status='running',startedAt=prior.now(),authorization='User 好 approved sole LD-P04 first batch',
        totalRowBudget=12036,originals=6,variants=17,newFilters=0,replays=0,builds=0,ABEEffectsRead=False,downloads=0,simulatorOperations=0))
    cat=read(P/'feature-catalog.json');defs=read(P/'atoms-no-outcome-ranking.json');frozen=read(PRE/'frozen-families.json')['candidates']
    proposal=read(PRE/'next-proposal.json');variants=proposal['singleCutAdjacentVariants']
    mats=[];keys=[];ops=[]
    for label in ['discovery','later']:
        data=np.load(P/(label+'.npz'));offset=len(keys);mats.append(data['X']);keys+=read(P/(label+'-keys.json'))
        for op in read(P/(label+'-opportunities.json')):
            op['indices']=[i+offset for i in op['indices']];ops.append(op)
    X=np.vstack(mats);anchors=[o['indices'][0]for o in ops]
    exits={(e['sample'],e['window'],e['anchor'],e['stock']):e['originalExitDate']for e in read(P/'timing-audit.json')['events']}
    counted=0
    def run(id,expr,has_s):
        nonlocal counted
        matrix=X[anchors]if has_s else X;mask,valid=evaluate(expr,defs,cat,matrix);counted+=len(matrix)
        assert counted<=12036
        states={j:(bool(mask>>i&1)if valid>>i&1 else None)for i,j in enumerate(anchors if has_s else range(len(X)))}
        events=[]
        for o in ops:
            indices=o['indices'];future=indices[1:];st=[states.get(i)for i in future];prices=[keys[i]['close']for i in future];dates=[keys[i]['date']for i in future]
            entry=states[indices[0]];rr=release(st,prices,dates,o['originalClose'],o['completeTen'],has_s)if entry is True else None
            exitday=exits[(o['sample'],o['window'],o['anchor'],o['stock'])]
            if rr and rr.get('date')is not None:rr['onOrAfterBaselineExit']=exitday is not None and rr['date']>=exitday
            events.append(dict(sample=o['sample'],window=o['window'],stock=o['stock'],anchor=o['anchor'],partition=o['partition'],
                trigger=entry,opportunity=o['qualifiedOpportunity'],originalClose=o['originalClose'],originalExitDate=exitday,
                futureDates=dates,futureStates=st,futurePrices=prices,firstLowerDate=o['firstLowerDate'],lowestDates=o['lowestDates'],release=rr))
        return dict(id=id,expr=expr,hasS=has_s,formula=' OR '.join('('+' AND '.join(f"{defs[i]['name']} {defs[i]['op']} {defs[i]['value']}"for i in b)+')'for b in expr),
            summary=summarize(events),discovery=summarize([e for e in events if e['partition']=='discovery']),
            later=summarize([e for e in events if e['partition']=='later']),events=events)
    cards=[run(f['id'],f['expr'],'S'in f['stratum'])for f in frozen]
    expected_later={f['id']:f['metrics']for f in read(PRE/'w3-check.json')['candidates']}
    for card,f in zip(cards,frozen):
        for partition,expected in [('discovery',f['metrics']),('later',expected_later[f['id']])]:
            for k in ['hits','lower','noLower','unavailable']:assert card[partition][k]==expected[k],(card['id'],partition,k)
    save('cards.json',cards)
    by={c['id']:c for c in cards};sensitivity=[]
    for n,v in enumerate(variants,1):
        result=run(f"{v['family']}-N{n:02}",v['expr'],v['hasS']);base=by[v['family']]
        added=[];lost=[];changes=[]
        for old,new in zip(base['events'],result['events']):
            key={k:new[k]for k in ['sample','window','stock','anchor','opportunity']}
            if new['trigger']is True and old['trigger']is not True:added.append(key)
            if old['trigger']is True and new['trigger']is not True:lost.append(key)
            if old['trigger']is True and new['trigger']is True and old['release']!=new['release']:changes.append(dict(**key,before=old['release'],after=new['release']))
        result.update(parent=v['family'],fromAtom=defs[v['fromAtom']],toAtom=defs[v['toAtom']],added=added,lost=lost,releaseChanges=changes)
        sensitivity.append(result)
    assert counted==12036 and len(sensitivity)==17
    save('sensitivity.json',sensitivity)
    for f,d in protected.items():assert sha(R/f)==d,f
    save('protected.json',protected)
    save('summary.json',dict(status='analysis-complete-awaiting-review',rowEvaluations=counted,protectedUnchanged=len(protected),
        cards=[{k:c[k]for k in ['id','formula','summary','discovery','later']}for c in cards],
        variants=[{k:c[k]for k in ['id','parent','summary','discovery','later']}for c in sensitivity]))
    print(json.dumps(dict(rows=counted,cards=[dict(id=c['id'],summary=c['summary'])for c in cards]),ensure_ascii=False))

if __name__=='__main__':main()
