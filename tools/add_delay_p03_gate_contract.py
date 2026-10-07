#!/usr/bin/env python3
"""Correct fixed T/M inapplicable inputs to the plan's no-extra-restriction rule.

Original 34-byte pair archives remain immutable. Separate archives carry
corrected release counts, audited against an independent first-stop algorithm.
No formula, threshold, anchor mask, quality label or S release is changed.
"""
import collections as C
import argparse
import struct
import time
import add_delay_p03 as a
import add_delay_p03_audit as audit

OUT=a.O/'gate-contract-v2'

def effective_result(x,y,data):
    mask=x['mask']&y['mask'];valid=x['valid']&y['valid'];waiting=mask&data['eligible'];quality=(mask&data['quality_unknown']).bit_count()
    if 'S' in (x['group'],y['group']):return mask,valid,(0,0,0,0,waiting.bit_count(),quality)
    lo=hi=eq=0
    for t,price in enumerate(data['price_days']):
        truth=x['days'][t][1]&y['days'][t][1]
        released=waiting&~truth
        lo+=(released&price[0]).bit_count();hi+=(released&price[1]).bit_count();eq+=(released&price[2]).bit_count();waiting&=truth
        if not waiting:break
    return mask,valid,(lo,hi,eq,waiting.bit_count(),0,quality)

def effective_oracle(x,y,mask,data):
    waiting=mask&data['eligible'];quality=(mask&data['quality_unknown']).bit_count()
    if 'S' in (x['group'],y['group']):return(0,0,0,0,waiting.bit_count(),quality)
    lo=hi=eq=0
    for t,price in enumerate(data['price_days']):
        stop=waiting&(x['stops'][t]|y['stops'][t])
        lo+=(stop&price[0]).bit_count();hi+=(stop&price[1]).bit_count();eq+=(stop&price[2]).bit_count();waiting&=~stop
        if not waiting:break
    return(lo,hi,eq,waiting.bit_count(),0,quality)

def archive_records(path):
    batch=path.parent.name.removeprefix('batch-');p=OUT/('batch-'+batch)/'pairs.bin'
    meta=a.read(OUT/'coverage-audit.json');assert a.sha(p)==meta['batches'][batch]['correctedSHA256']
    yield from a.records(p)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('batch',choices=['A','B']);args=parser.parse_args()
    OUT.mkdir(exist_ok=True);assert not(OUT/'coverage-audit.json').exists()
    assert a.read(a.O/'coverage-audit.json')['passed']
    protected=a.verify_sources();data=a.inputs();ind=audit.independent_inputs();batches={};changed=C.Counter()
    for batch in (args.batch,):
        cp=a.read(a.O/('batch-'+batch)/'checkpoint.json')
        limits=dict(a.read(a.O/'protocol.json')['limits']);limits['coreSecondsPerBatch']-=cp['coreSeconds']
        assert limits['coreSecondsPerBatch']>0
        guard=a.Guard(limits=limits)
        identity=dict(batch=batch,contract='fixed-TM-missing-means-no-extra-gate',originalArchive=cp['prefixSHA256'],sourceHashes=protected,correctionToolSHA256=a.sha(__file__))
        # Reuse the tested transactional runner, changing only the pure evaluator.
        original_evaluator=a.result
        try:
            a.result=effective_result
            state=a.pair_run(data,batch,OUT/('batch-'+batch),identity,guard,expected=a.EXPECTED[batch])
        finally:a.result=original_evaluator
        if state['status']!='complete':
            print(dict(status='paused',batch=batch,checkpoint=state));return
        updates=C.Counter();count=0;check_guard=a.Guard();check_guard.check();check_guard.watch()
        original_path=a.O/('batch-'+batch)/'pairs.bin';corrected_path=OUT/('batch-'+batch)/'pairs.bin'
        for old,new in zip(a.records(original_path),a.records(corrected_path),strict=True):
            assert old[:4]==new[:4],('formula/mask changed',batch,count)
            i,j,mb,vb,*r=new;mask=int.from_bytes(mb,'little')
            assert tuple(r)==effective_oracle(ind['atoms'][i],ind['atoms'][j],mask,ind)
            group=a.source_group(data['atoms'][i],data['atoms'][j])
            if old!=new:updates[group]+=1
            if 'S' in group:assert old==new
            count+=1
            if count%200000==0:check_guard.check()
        check_guard.finish();assert count==a.EXPECTED[batch]
        changed.update(updates)
        batches[batch]=dict(records=count,changedBySource=dict(updates),correctedSHA256=a.sha(corrected_path),originalSHA256=cp['prefixSHA256'],
            originalCoreSeconds=cp['coreSeconds'],correctionCoreSeconds=state['coreSeconds'],totalCoreSeconds=cp['coreSeconds']+state['coreSeconds'],
            independentOracleSeconds=check_guard.seconds(),peakRSSBytes=max(state['peakRSSBytes'],check_guard.peak_rss),peakArtifactBytes=max(state['peakArtifactBytes'],check_guard.peak_disk))
        a.save(OUT/('correction-'+batch+'.json'),dict(batches[batch],toolSHA256=a.sha(__file__)),a.Guard())
    for rel,h in protected.items():assert a.sha(a.R/rel)==h,rel
    if not all((OUT/('correction-'+b+'.json')).exists() for b in ('A','B')):
        print(dict(correctedBatch=args.batch,result=batches[args.batch]));return
    batches={b:a.read(OUT/('correction-'+b+'.json')) for b in ('A','B')}
    changed=C.Counter()
    for b in batches.values():
        assert b['toolSHA256']==a.sha(__file__)
        changed.update(b['changedBySource'])
    a.save(OUT/'coverage-audit.json',dict(passed=True,formulaRecords=sum(x['records'] for x in batches.values()),newFormulaStructures=0,newThresholds=0,
        originalCoverageSHA256=a.sha(a.O/'coverage-audit.json'),batches=batches,changedBySource=dict(changed),
        reason='Plan section 3: missing/inapplicable fixed T/M input cannot impose the additional delay; first such day is gate pass-through. Own S and quality unknown remain unknown.',
        frozenOriginalsPreserved=True,toolSHA256=a.sha(__file__)),a.Guard())
    print(dict(corrected=True,batches=batches,changed=dict(changed)))

if __name__=='__main__':main()
