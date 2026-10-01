#!/usr/bin/env python3
"""Retain mixed-outcome families from already-evaluated saved candidates.
No new expression generation, threshold change, or search. Required pre-freeze
retention audit: precision ordering otherwise crowds the small-counterexample lane.
"""
from collections import Counter,defaultdict
import sell_delay_p03 as p

def main():
    assert not (p.O/'frozen-families.json').exists() and not (p.O/'completion.json').exists()
    _,defs,atoms,screen=p.context();existing=p.read(p.O/'retained.json')
    by=defaultdict(list)
    for expr in p.read(p.O/'batch-1.json')['reservoir']:
        n=p.engine.make_node(expr,atoms,screen.rank);pos,neg,pr,c=screen.basic(n.mask,n.valid)
        # This lane's definition is majority-positive with at least one counterexample.
        # It does not veto any entry in the main retention pool.
        if pos>neg>0:by[n.stratum].append(n)
    chosen=[];seen={tuple(tuple(b)for b in r['expr'])for r in existing}
    for source,rows in sorted(by.items()):
        parent_counts=Counter()
        for n in sorted(rows,key=lambda n:(screen.basic(n.mask,n.valid)[2],screen.basic(n.mask,n.valid)[0]),reverse=True):
            fam=tuple(sorted(atoms[i].parent for i in n.expr[0]))
            if n.expr in seen or parent_counts[fam]>=2:continue
            seen.add(n.expr);parent_counts[fam]+=1;chosen.append(n)
            if sum(parent_counts.values())>=12:break
    recovered=[dict(poolID=f'M{i+1:03}',expr=n.expr,stratum=n.stratum,expression=p.expression(n.expr,defs),rank=n.score,repairRank=screen.repair_rank(n.mask,n.valid),metrics=screen.metrics(n.mask,n.valid),provenance='already evaluated AND2; batch-1 reservoir')for i,n in enumerate(chosen)]
    assert any(0<r['metrics']['noHigher']<r['metrics']['higher']for r in recovered)
    p.save('mixed-retention-audit.json',dict(reason='Final dual-ordering beam favors either zero-counterexample or broad-discrimination families; preserve a separate mixed lane before freezing',source='batch-1.json reservoir, plus original retained.json remains intact',previouslyEvaluatedExamined=len(p.read(p.O/'batch-1.json')['reservoir']),newExpressions=0,newThresholds=0,added=len(recovered),bySource=dict(Counter(r['stratum']for r in recovered)),records=recovered))
    p.save('review-pool.json',existing+recovered)
    print('MIXED_RETENTION',len(recovered),'total',len(existing+recovered))

if __name__=='__main__':main()
