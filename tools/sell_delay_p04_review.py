#!/usr/bin/env python3
"""Freeze, sensitivity, causal field contrasts and independent controls for SD-P04."""
from collections import Counter
import json, sys, sqlite3
import numpy as np
import sell_delay_p04 as q
from sell_delay_p04 import O,P,R,read,save,sha,canon,p,Context

def freeze():
    assert not (O/'frozen-review.json').exists()
    fs=read(p.O/'frozen-families.json')['families'];short=read(O/'train-shortlist.json');sel=read(O/'selected-atoms.json')['families'];rows=[]
    for f,s,ss in zip(fs,short,sel):
        base=canon(f['expr']);chosen=[dict(id=f['family']+'-original',expr=base,reason='原式與修正版並列')]
        if f['family'] not in ('SD-F04','SD-F05'):
            best=s['shortlist'][0];chosen.append(dict(id=f['family']+'-R1',expr=best['expr'],reason='W1/W2最高較高解除比例候選，保留代價完整核對'))
            single=next((r for r in s['shortlist'] if r['kind']=='add1AND'),None)
            if single:chosen.append(dict(id=f['family']+'-simple',expr=single['expr'],reason='較簡單附加條件對照，非另開搜尋'))
        if f['family']=='SD-F04':
            for a in ss['atoms']:chosen.append(dict(id=f['family']+'-A'+str(a['id']),expr=canon(q.add(base,[a['id']])),reason='已選24原子之一；W3單一反例診斷，若據此選式則W3參與修正'))
        for r in chosen:r.update(family=f['family'],expression=p.expression(r['expr'],read(P/'atoms-no-outcome-ranking.json')))
        rows.extend(chosen)
    save('frozen-review.json',dict(status='frozen-before-new-W3-checks',trainASHA256=sha(O/'stage-a.json'),trainBSHA256=sha(O/'stage-b.json'),records=rows,W3OriginalResultsAlreadySeen=True,repeatW3OptimizationAllowed=False))

def review():
    assert not (O/'review.json').exists()
    frozen=read(O/'frozen-review.json');out=[];counter=0
    for label in ('discovery','later'):
        c=Context(label);base={f['family']:c.outcomes(f['expr'])[0] for f in read(p.O/'frozen-families.json')['families']}
        for r in frozen['records']:
            counter+=1;out.append(dict(**r,partition=label,metrics=c.evaluate(r['expr'],base[r['family']]),cases=c.details(r['expr'])))
    save('review.json',out);save('review-budget.json',dict(evaluations=counter,frozenSHA256=sha(O/'frozen-review.json')))

def sensitivity():
    assert not (O/'sensitivity.json').exists()
    rows=read(O/'frozen-review.json')['records'];defs=read(P/'atoms-no-outcome-ranking.json');experiments=[];seen=set()
    for r in rows:
        if not(r['id'].endswith('original') or r['id'].endswith('R1')):continue
        e=canon(r['expr']);atomids=sorted({i for b in e for i in b})
        for i in atomids:
            # Remove an entire field consistently from all branches; one-parent branches are diagnostic only.
            ex=canon([tuple(k for k in b if k!=i) for b in e]);ex=tuple(sorted(set(ex)))
            if all(ex):experiments.append(dict(parent=r['id'],kind='deleteAtom',expr=ex))
            a=defs[i]
            if a['op'] not in ('lt','gt','between'):continue
            same=[x for x in defs if x['name']==a['name'] and x['op']==a['op']]
            same=sorted(same,key=lambda x:x['value']);pos=next(j for j,x in enumerate(same) if x['id']==i)
            for j in (pos-1,pos+1):
                if 0<=j<len(same):experiments.append(dict(parent=r['id'],kind='adjacentCoarse',expr=canon([[same[j]['id'] if k==i else k for k in b]for b in e])))
        if len(e)==2:
            for branch in e:experiments.append(dict(parent=r['id'],kind='ORbranchAlone',expr=(branch,)))
    unique=[]
    for r in experiments:
        key=(r['parent'],r['expr'])
        if key in seen:continue
        seen.add(key);unique.append(r)
    out=[]
    for label in ('discovery','later'):
        c=Context(label)
        for r in unique:out.append(dict(**r,expression=p.expression(r['expr'],defs),partition=label,metrics=c.evaluate(r['expr']),eligibleCandidateGrammar=c.legal(r['expr']),usedForRefit=False))
    save('sensitivity.json',out);save('sensitivity-budget.json',dict(evaluations=len(out),frozenNoRefit=True))

def fields():
    # 292-column contrasts are descriptive, not additional rule/threshold search.
    out=[];trajectories=[]
    fs=read(p.O/'frozen-families.json')['families']
    for label in ('discovery','later'):
        c=Context(label)
        for f in fs:
            st,off,d,h,v=c.outcomes(f['expr']);hits=st>0
            pos=hits&c.pos;bad=hits&((st==2)|c.neg);good=hits&(st==1)
            cols=[]
            for j,col in enumerate(c.cat):
                vals={}
                for name,mask in [('opportunity',pos),('higherRelease',good),('counterexample',bad)]:
                    x=c.X[c.anchors[mask],j];x=x[np.isfinite(x)];vals[name]=dict(known=len(x),median=float(np.median(x)) if len(x) else None,min=float(np.min(x))if len(x)else None,max=float(np.max(x))if len(x)else None)
                cols.append(dict(name=col['name'],group=col['group'],values=vals))
            out.append(dict(family=f['family'],partition=label,columns=cols))
            involved={c.defs[i]['name'] for b in f['expr'] for i in b}
            # Include selected repair fields in raw timelines, both positive and negative cases.
            for rr in read(O/'frozen-review.json')['records']:
                if rr['family']==f['family'] and (rr['id'].endswith('R1') or rr['id'].endswith('simple')):involved|={c.defs[i]['name'] for b in rr['expr'] for i in b}
            for j in np.flatnonzero(hits):
                op=c.ops[j];days=[]
                for idx in op['indices']:
                    days.append(dict(date=c.keys[idx]['date'],close=c.keys[idx]['close'],values={n:float(c.X[idx,c.col[n]])if np.isfinite(c.X[idx,c.col[n]])else None for n in sorted(involved)}))
                trajectories.append(dict(family=f['family'],partition=label,stock=op['stock'],anchor=op['anchor'],result=q.NAMES[st[j]],opportunity=op['qualifiedOpportunity'],highestDates=op['higherHighestDates'],days=days))
    save('field-contrasts.json',out);save('original-timelines.json',trajectories)

def overlap():
    ident=read(R/'exports/sell-delay-p01-20260930/identities.json');vote={}
    for s,d in ident.items():
        path=R/d['decisionBase']/'decisions.sqlite'
        c=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True);c.row_factory=sqlite3.Row
        for row in c.execute("select v.*,r.rule_id from event_votes v join rules r using(rule_key) where r.rule_id like 'S-N%'"):
            if row['contribution']<0:vote.setdefault((s,row['event_id']),[]).append(dict(rule=row['rule_id'],contribution=row['contribution']))
        c.close()
    out=[]
    for label in ('discovery','later'):
        c=Context(label)
        for r in read(O/'frozen-review.json')['records']:
            st=c.outcomes(r['expr'])[0];rules=Counter();cases=[]
            for j in np.flatnonzero(st):
                op=c.ops[j];vs=vote.get((op['sample'],op['event']),[]);rules.update(x['rule'] for x in vs);cases.append(dict(sample=op['sample'],stock=op['stock'],date=op['anchor'],exitRoute=op['exitRoute'],votes=vs))
            out.append(dict(id=r['id'],partition=label,hits=len(cases),anyExistingReluctance=sum(bool(x['votes'])for x in cases),ruleCounts=dict(rules),cases=cases))
    save('overlap.json',out)

if __name__=='__main__':
    assert not (O/'completion.json').exists(), 'Completed P04 evidence is immutable'
    globals()[sys.argv[1]]()
