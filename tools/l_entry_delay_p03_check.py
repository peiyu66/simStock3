#!/usr/bin/env python3
"""Independent scalar evaluation of frozen six, then W3; never reselect formulas."""
import collections as C, json
import numpy as np
import l_entry_delay_p03 as p

def evaluate(expr,defs,cat,X):
    columns={c['name']:i for i,c in enumerate(cat)};mask=valid=0
    for row,x in enumerate(X):
        all_valid=True;branches=[]
        for branch in expr:
            accepted=True
            for i in branch:
                d=defs[i];v=x[columns[d['name']]];threshold=d['value']
                if not np.isfinite(v):all_valid=False;accepted=False;continue
                if d['op']=='gt':hit=v>threshold
                elif d['op']=='lt':hit=v<threshold
                elif d['op']=='eq':hit=v==threshold
                elif d['op']=='ne':hit=v!=threshold
                elif d['op']=='between':hit=threshold[0]<v<threshold[1]
                else:raise AssertionError(d)
                accepted=accepted and hit
            branches.append(accepted)
        if all_valid:
            valid|=1<<row
            if any(branches):mask|=1<<row
    return mask,valid

def main():
    assert not(p.O/'completion.json').exists()and not(p.O/'w3-check.json').exists()
    frozen=p.read(p.O/'frozen-families.json');assert frozen['W3ReadForSelection']is False
    digest=p.sha(p.O/'frozen-families.json');families=frozen['candidates'];assert len(families)<=6
    cat=p.read(p.P/'feature-catalog.json');defs=p.read(p.P/'atoms-no-outcome-ranking.json')
    data=np.load(p.P/'discovery.npz');X=data['X'][data['anchors']]
    for f in families:
        assert evaluate(f['expr'],defs,cat,X)==(f['mask'],f['valid']),f['id']
    # This is the first semantic load of W3 for formula evaluation in LD-P03.
    opened=p.now();data=np.load(p.P/'later.npz');X=data['X'][data['anchors']];ops=p.read(p.P/'later-opportunities.json')
    checked=[]
    for f in families:
        m,v=evaluate(f['expr'],defs,cat,X);metric=p.metrics(m,v,ops)
        hits=[dict(sample=o['sample'],window=o['window'],stock=o['stock'],anchor=o['anchor'],
            lower=o['qualifiedOpportunity'],minimumChangePct=o['minimumChangePct'])for i,o in enumerate(ops)if m>>i&1]
        checked.append(dict(id=f['id'],formula=f['formula'],mask=m,valid=v,metrics=metric,events=hits))
    assert p.sha(p.O/'frozen-families.json')==digest
    b1=p.read(p.O/'batch1.json');b2=p.read(p.O/'batch2.json')
    expected=p.read(p.P/'search-budget.json')
    assert b1['counts']=={'AND2':expected['AND2']}
    assert sum(b2['counts'].values())+len(families)<=814306
    total=sum(b1['counts'].values())+sum(b2['counts'].values())+len(families)
    assert total<=2777154
    assert set().union(*(set(v)for v in b2['bySource'].values()))==set(p.g.STRATA)
    for path,d in p.read(p.O/'protected.json').items():assert p.sha(p.R/path)==d,path
    p.save('w3-check.json',dict(frozenSHA256=digest,frozenAt=frozen['frozenAt'],W3OpenedAt=opened,
        completedAt=p.now(),evaluated=len(families),candidates=checked,reselected=False))
    p.save('audit.json',dict(passed=True,frozenDiscoveryScalarChecks=len(families),W3Evaluations=len(families),
        totalSearchAndW3Evaluations=total,budget=2777154,sevenSources=True,
        protectedUnchanged=len(p.read(p.O/'protected.json')),sourceToolSHA256=p.sha(__file__)))
    for r in checked:print(r['id'],r['metrics'])

if __name__=='__main__':main()
