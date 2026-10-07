#!/usr/bin/env python3
"""Low-cost durable resume and limit controls; no extra real formula search."""
import hashlib
import json
from pathlib import Path
from unittest.mock import patch
import add_delay_p03 as a

def main():
    root=a.O/'controls';assert not root.exists(),'Completed controls are immutable';root.mkdir()
    atoms=[]
    for i in range(18):
        g='TSM'[i%3];valid=(1<<9)-1;mask=sum(1<<k for k in range(9) if (k+i)%3!=0)
        days=[(valid if t!=3 else valid&~2,mask if t%3 else valid&~(1<<(i%9))) for t in range(10)]
        atoms.append(dict(id=i,parent='parent'+str(i//2),group=g,mask=mask,valid=valid,days=days))
    data=dict(atoms=atoms,eligible=255,quality_unknown=256,price_days=[(15,240,256)]*10)
    checks={};fingerprint=dict(synthetic=True,atoms=atoms)
    for batch in ('A','B'):
        expected=sum(1 for i,x in enumerate(atoms) for y in atoms[i+1:] if x['parent']!=y['parent'] and a.source_group(x,y) in a.GROUPS[batch])
        full=a.pair_run(data,batch,root/(batch+'-full'),fingerprint,a.Guard(),expected=expected,chunk=7)
        first=a.pair_run(data,batch,root/(batch+'-resume'),fingerprint,a.Guard(),pause_after=11,chunk=7)
        assert first['count']==11 and first['status']=='paused'
        p=root/(batch+'-resume')/'pairs.bin'
        with p.open('ab') as f:f.write(b'uncommitted-tail')
        final=a.pair_run(data,batch,root/(batch+'-resume'),fingerprint,a.Guard(),expected=expected,chunk=7)
        assert final['resumes']==1 and final['recoveredTailBytes']==16 and final['coreSeconds']>=first['coreSeconds']
        assert p.read_bytes()==(root/(batch+'-full')/'pairs.bin').read_bytes()
        records=list(a.records(p));assert len(records)==expected
        # Explicit event/day oracle, independent of production bitset transitions.
        for i,j,mb,vb,lo,hi,eq,wait,unknown,quality in records:
            x,y=atoms[i],atoms[j];mask=x['mask']&y['mask'];counts=[0]*6
            for k in range(9):
                if not mask>>k&1:continue
                if not data['eligible']>>k&1:counts[5]+=1;continue
                if 'S' in (x['group'],y['group']):counts[4]+=1;continue
                for t in range(10):
                    if not(x['days'][t][0]>>k&1 and y['days'][t][0]>>k&1):counts[4]+=1;break
                    if not(x['days'][t][1]>>k&1 and y['days'][t][1]>>k&1):
                        counts[0 if k<4 else 1 if k<8 else 2]+=1;break
                else:counts[3]+=1
            assert counts==[lo,hi,eq,wait,unknown,quality]
        checks[batch]=dict(pairs=expected,prefix=11,resumeIdentical=True,uncommittedTailRecovered=16,oracleRecords=len(records))
        try:a.pair_run(data,batch,root/(batch+'-resume'),dict(changed=True),a.Guard())
        except AssertionError as e:assert 'identity' in str(e)
        else:raise AssertionError('identity mismatch accepted')
    # Resource guards are injected at exact thresholds; no large allocation/write.
    g=a.Guard()
    with patch.object(a,'rss',return_value=2147483648):assert g.probe()=='memory-limit'
    assert g.probe(256000000)=='artifact-limit'
    g.prior=600;assert g.probe()=='core-time-limit'
    # A real early time stop persists a safe prefix, then resumes without extending
    # the production budget; test allowance is explicit and isolated.
    limits=dict(memoryBytes=2147483648,totalArtifactBytes=256000000,coreSecondsPerBatch=.003)
    stopped=a.pair_run(data,'A',root/'time-stop',fingerprint,a.Guard(limits=limits),chunk=1)
    assert stopped['status']=='paused' and stopped['reason']=='core-time-limit'
    checks['limits']=dict(memoryBoundary=True,projectedDiskBoundary=True,timeBoundary=True,timeStopSavedCount=stopped['count'])
    checks['productionRecordBytes']=a.RECORD.size
    a.save(root/'completion.json',dict(passed=True,checks=checks,scriptSHA256=a.sha(__file__)),a.Guard())
    print(json.dumps(dict(passed=True,checks=checks)))

if __name__=='__main__':main()
