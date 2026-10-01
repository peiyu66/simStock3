#!/usr/bin/env python3
"""Chronological diagnostics of retained SD-P03 expressions; freeze before W3."""
from collections import Counter
import json,math,sys
import numpy as np
import sell_delay_p03 as p
from sell_delay_p03 import P,O,read,save,sha,engine

def evaluate(label,records):
    cat=read(P/'feature-catalog.json');defs=read(P/'atoms-no-outcome-ranking.json')
    data=np.load(P/f'{label}.npz');X=data['X'];ops=read(P/f'{label}-opportunities.json');keys=read(P/f'{label}-keys.json')
    atoms=[engine.Atom(**a,mask=engine.bits(m),valid=engine.bits(v))for a,(m,v)in zip(defs,p.arrays(defs,X,cat))]
    anchors=data['anchors'];sc=p.Screen(ops);reports=[]
    for r in records:
        node=engine.make_node(r['expr'],atoms,lambda m,v:(0,));assert node is not None
        imask=engine.bits([bool(node.mask&(1<<int(i)))for i in anchors]);iv=engine.bits([bool(node.valid&(1<<int(i)))for i in anchors])
        metrics=sc.metrics(imask,iv)
        if label=='discovery':assert metrics==r['metrics'],(r['poolID'],'anchor metrics mismatch')
        cases=[];counts=Counter();price_deltas=[];net_deltas=[]
        for j,op in enumerate(ops):
            if not imask&(1<<j):continue
            result='stillTrue10' if op['completeTen'] else 'windowTruncated';offset=None;release=None
            for d,i in enumerate(op['indices'][1:],1):
                if not node.valid&(1<<i):result='unknownInputs';offset=d;break
                if not node.mask&(1<<i):
                    release=keys[i];offset=d
                    result='higherRelease' if release['close']>op['originalClose'] else 'lowerRelease' if release['close']<op['originalClose'] else 'equalRelease'
                    break
            raw=result
            if op['qualifiedOpportunity'] is None:result='dataUnknown'
            counts[result]+=1
            rec=dict(sample=op['sample'],window=op['window'],stock=op['stock'],anchor=op['anchor'],opportunity=op['qualifiedOpportunity'],highestDates=op['higherHighestDates'],qualityStatus=op['qualityStatus'],result=result,observedResult=raw,firstOffOrUnknownOffset=offset,firstOffDate=release['date'] if release else None,firstOffPrice=release['close'] if release else None)
            if release:
                rec['releasePriceDeltaPct']=100*(release['close']/op['originalClose']-1)
                rec['netProceedsDelta']=op['netProceedsDelta'][offset-1]
                if result!='dataUnknown':price_deltas.append(rec['releasePriceDeltaPct']);net_deltas.append(rec['netProceedsDelta'])
            cases.append(rec)
        assert sum(counts.values())==metrics['hits']
        # Independent row-wise NumPy evaluation, including strict missingness across OR branches.
        valid=np.ones(len(X),dtype=bool);hit=np.zeros(len(X),dtype=bool);column={c['name']:i for i,c in enumerate(cat)}
        for branch in r['expr']:
            branch_hit=np.ones(len(X),dtype=bool)
            for i in branch:
                a=defs[i];x=X[:,column[a['name']]];v=a['value'];valid&=np.isfinite(x)
                if a['op']=='lt':h=x<v
                elif a['op']=='gt':h=x>v
                elif a['op']=='eq':h=x==v
                elif a['op']=='ne':h=x!=v
                else:h=(x>v[0])&(x<v[1])
                branch_hit&=h
            hit|=branch_hit
        hit&=valid;assert engine.bits(hit)==node.mask and engine.bits(valid)==node.valid
        reports.append(dict(**{k:r[k]for k in ('poolID','expr','expression','stratum')},partition=label,metrics=metrics,proxy=dict(counts),medianKnownReleasePct=float(np.median(price_deltas))if price_deltas else None,medianFixedInventoryNetDelta=float(np.median(net_deltas))if net_deltas else None,cases=cases,actualSellEligibilityChecked=False))
    return reports

def train():
    assert not (O/'frozen-families.json').exists()
    r=read(O/'review-pool.json');out=evaluate('discovery',r);save('train-diagnostics.json',out)
    save('train-shortlist.json',[{k:v for k,v in r.items()if k!='cases'}for r in out])
    save('diagnostic-controls.json',dict(trainExpressions=len(out),fullMatrixBooleanControls=len(out),originalAnchorControls=len(out),W3Read=False))
    print('TRAIN_DIAGNOSTICS',len(out))

def freeze(ids):
    assert not (O/'frozen-families.json').exists() and 0<len(ids)<=6 and len(set(ids))==len(ids)
    rows=read(O/'train-diagnostics.json');lookup={r['poolID']:r for r in rows};assert all(i in lookup for i in ids)
    families=[]
    for i,ident in enumerate(ids):
        r=lookup[ident];families.append(dict(family=f'SD-F{i+1:02}',**{k:r[k]for k in ('poolID','expr','expression','stratum','metrics','proxy')}))
    save('frozen-families.json',dict(status='frozen-before-W3',ids=ids,trainDiagnosticsSHA256=sha(O/'train-diagnostics.json'),retainedSHA256=sha(O/'review-pool.json'),families=families))
    print('FROZEN',ids)

def later():
    frozen=read(O/'frozen-families.json');assert frozen['status']=='frozen-before-W3'
    assert sha(O/'train-diagnostics.json')==frozen['trainDiagnosticsSHA256']
    records=[r for r in read(O/'review-pool.json')if r['poolID']in frozen['ids']]
    save('later-diagnostics.json',evaluate('later',records))
    c=read(O/'diagnostic-controls.json');c.update(laterExpressions=len(records),W3ReadAfterFreeze=True,frozenSHA256=sha(O/'frozen-families.json'));save('diagnostic-controls.json',c)
    print('LATER_DIAGNOSTICS',len(records))

if __name__=='__main__':
    assert not (O/'completion.json').exists()
    if sys.argv[1]=='train':train()
    elif sys.argv[1]=='freeze':freeze(sys.argv[2:])
    elif sys.argv[1]=='later':later()
