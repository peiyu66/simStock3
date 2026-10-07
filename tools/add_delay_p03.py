#!/usr/bin/env python3
"""AD-P03 fixed pair archive with bounded resources and durable prefix resume.

No App, simulation or new thresholds. Every allowed pair is retained, even when
its anchor mask equals another formula. S-dependent release remains unknown.
"""
import argparse
import collections as C
import fcntl
import hashlib
import json
import os
from pathlib import Path
import resource
import signal
import struct
import sys
import threading
import time
import numpy as np
import h_entry_composite_search as gen

R=Path(__file__).resolve().parents[1]
P=R/'exports/add-delay-p02-20261002'
O=R/'exports/add-delay-p03-20261002'
RECORD=struct.Struct('<HH12s12s6B')
GROUPS={'A':{'T','S','M','TS'},'B':{'TM','SM'}}
EXPECTED={'A':1044027,'B':1053700}
STOP=threading.Event()
SIGNAL_REASON=''

def read(p):return json.loads(Path(p).read_text())
def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()
def digest(x):return hashlib.sha256(json.dumps(x,sort_keys=True,separators=(',',':')).encode()).hexdigest()
def source_group(a,b):return ''.join(g for g in 'TSM' if g in (a['group'],b['group']))
def rss():return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss*(1 if sys.platform=='darwin' else 1024)

class LimitStop(Exception):pass

class Guard:
    def __init__(self,root=O,limits=None,prior_seconds=0):
        self.root=Path(root);self.limits=limits or read(O/'protocol.json')['limits']
        self.prior=prior_seconds;self.start=None;self.peak_rss=0;self.peak_disk=0
        self.reason='';self.finished=threading.Event();self.thread=None
    def bytes(self):
        extra=[*R.glob('tools/*add_delay_p03*.py'),R/'doc/補買延遲複合規則研究計畫-20261002.md',R/'doc/README.md',R/'doc/工作交接.md',R/'doc/回測規則驗證.md']
        total=0
        for p in [*self.root.rglob('*'),*extra]:
            try:
                if p.is_file():total+=p.stat().st_size
            except FileNotFoundError:pass # an atomic temporary file was renamed
        return total
    def seconds(self):
        start=self.start
        return self.prior+(time.monotonic()-start if start is not None else 0)
    def probe(self,additional=0):
        mem=rss();disk=self.bytes();self.peak_rss=max(self.peak_rss,mem);self.peak_disk=max(self.peak_disk,disk)
        if mem>=self.limits['memoryBytes']:return 'memory-limit'
        if disk+additional+65536>=self.limits['totalArtifactBytes']:return 'artifact-limit'
        if self.seconds()>=self.limits['coreSecondsPerBatch']:return 'core-time-limit'
        if STOP.is_set():return SIGNAL_REASON or 'interruption-requested'
        return ''
    def check(self,additional=0):
        reason=self.reason or self.probe(additional)
        if reason:raise LimitStop(reason)
    def watch(self):
        self.start=time.monotonic()
        def loop():
            while not self.finished.wait(.05):
                reason=self.probe()
                if reason:self.reason=reason;break
        self.thread=threading.Thread(target=loop,daemon=True);self.thread.start()
    def finish(self):
        self.finished.set()
        if self.thread:self.thread.join(timeout=.2)
        if self.start is not None:
            self.prior=self.seconds();self.start=None

def save(path,x,guard=None,emergency=False):
    path=Path(path);data=(json.dumps(x,ensure_ascii=False,indent=2,allow_nan=False)+'\n').encode()
    if guard and not emergency:guard.check(len(data))
    if emergency:assert len(data)<32768,'Reserved stop metadata exceeded'
    tmp=path.with_suffix(path.suffix+'.tmp')
    with tmp.open('wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
    tmp.replace(path)

def verify_sources():
    acceptance=read(P/'acceptance.json');assert acceptance['status']=='accepted'
    for n,key in [('completion.json','completionSHA256'),('audit.json','independentAuditSHA256'),('quality-labels.json','qualityLabelsSHA256')]:assert sha(P/n)==acceptance[key],n
    done=read(P/'completion.json');assert done['status']=='complete'
    protected={str((P/n).relative_to(R)):h for n,h in done['artifacts'].items()}
    protected.update(read(P/'source-hashes.json'))
    for n in ('acceptance.json','completion.json','audit.json','quality-labels.json'):protected[str((P/n).relative_to(R))]=sha(P/n)
    for f in (Path(__file__),R/'tools/h_entry_composite_search.py',O/'protocol.json'):protected[str(f.relative_to(R))]=sha(f)
    for rel,h in protected.items():assert sha(R/rel)==h,('changed source',rel)
    return protected

def inputs(part='discovery'):
    cat=read(P/'feature-catalog.json');specs=read(P/'atoms-no-outcome-ranking.json')
    data=np.load(P/(part+'.npz'));X=data['X'];entries=data['anchors'];keys=read(P/(part+'-keys.json'))
    ops=read(P/(part+'-opportunities.json'));labels=[r for r in read(P/'quality-labels.json')['rows'] if r['partition']==part]
    assert len(entries)==len(ops)==len(labels) and len(entries)<=96
    if part=='discovery':
        generated=gen.make_atoms(X[entries],cat)
        got=[dict(id=a.id,name=a.name,parent=a.parent,group=a.group,op=a.op,value=a.value) for a in generated]
        assert json.loads(json.dumps(got))==specs,'Frozen thresholds changed'
    by={c['name']:j for j,c in enumerate(cat)};bits=lambda x:sum(1<<i for i,v in enumerate(x) if v)
    atoms=[];eligible=0;lower=0;quality_unknown=0;prices=[]
    for i,(op,l) in enumerate(zip(ops,labels)):
        assert tuple(op[k] for k in ('sample','window','stock','anchor'))==tuple(l[k] for k in ('sample','window','stock','anchor'))
        if l['eligible']:eligible|=1<<i
        else:quality_unknown|=1<<i
        if l['opportunity'] is True:lower|=1<<i
        changes=op['dailyChangePct'];prices.append(changes)
    scols=[j for j,c in enumerate(cat) if c['group']=='S']
    assert np.isnan(X[np.array([k['offset']>0 for k in keys])][:,scols]).all()
    for s in specs:
        column=X[:,by[s['name']]];valid=np.isfinite(column);v=s['value'];op=s['op']
        truth=valid&({'lt':lambda:column<v,'gt':lambda:column>v,'eq':lambda:column==v,'ne':lambda:column!=v,'between':lambda:(column>v[0])&(column<v[1])}[op]())
        a=dict(s,mask=bits(truth[entries]),valid=bits(valid[entries]),days=[])
        for offset in range(1,11):
            good=hit=0
            for i,o in enumerate(ops):
                if len(o['indices'])>offset:
                    idx=o['indices'][offset]
                    if valid[idx]:good|=1<<i
                    if truth[idx]:hit|=1<<i
            a['days'].append((good,hit))
        atoms.append(a)
    assert len(atoms)==2053
    days=[]
    for offset in range(10):
        days.append(tuple(sum(1<<i for i,ps in enumerate(prices) if len(ps)>offset and compare(ps[offset])) for compare in (lambda v:v<0,lambda v:v>0,lambda v:v==0)))
    return dict(atoms=atoms,eligible=eligible,lower=lower,quality_unknown=quality_unknown,price_days=days,ops=ops,labels=labels,entries=entries,X=X,keys=keys,cat=cat)

def result(a,b,data):
    mask=a['mask']&b['mask'];valid=a['valid']&b['valid'];waiting=mask&data['eligible']
    quality=(mask&data['quality_unknown']).bit_count()
    if 'S' in (a['group'],b['group']):return mask,valid,(0,0,0,0,waiting.bit_count(),quality)
    lo=hi=eq=unknown=0
    for t,price in enumerate(data['price_days']):
        va,ta=a['days'][t];vb,tb=b['days'][t];finite=va&vb
        missing=waiting&~finite;unknown+=missing.bit_count();waiting&=finite
        released=waiting&~(ta&tb)
        lo+=(released&price[0]).bit_count();hi+=(released&price[1]).bit_count();eq+=(released&price[2]).bit_count()
        waiting&=ta&tb
        if not waiting:break
    return mask,valid,(lo,hi,eq,waiting.bit_count(),unknown,quality)

def pair_run(data,batch,directory,identity,guard,pause_after=None,expected=None,chunk=4096):
    """Resume only a verified durable prefix. Returns completed or paused state."""
    directory=Path(directory);directory.mkdir(parents=True,exist_ok=True)
    lock=(directory/'lock').open('a+b')
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:lock.close();raise RuntimeError('This batch is already in use')
    path=directory/'pairs.bin';cpfile=directory/'checkpoint.json';atoms=data['atoms'];n=len(atoms)
    ident=digest(identity);hasher=hashlib.sha256();state=dict(status='new',fingerprint=ident,count=0,cursor=[0,1],coreSeconds=0.,counts={},prefixSHA256=hasher.hexdigest(),recordBytes=RECORD.size,resumes=0,recoveredTailBytes=0)
    if cpfile.exists():
        state=read(cpfile);assert state['fingerprint']==ident and state['recordBytes']==RECORD.size,'Checkpoint identity mismatch'
        size=state['count']*RECORD.size;assert path.exists() and path.stat().st_size>=size,'Missing committed data'
        with path.open('rb') as f:
            left=size
            while left:
                block=f.read(min(left,1048576));hasher.update(block);left-=len(block)
        assert hasher.hexdigest()==state['prefixSHA256'],'Committed prefix checksum mismatch'
        if state['status']=='complete':lock.close();return state
        if state['status']=='running':
            # A killed process has unknown unsaved CPU time: conservatively charge
            # elapsed wall time since its last checkpoint, capped at the budget.
            state['coreSeconds']=min(guard.limits['coreSecondsPerBatch'],state['coreSeconds']+max(0,time.time()-state['wallSaved']))
        tail=path.stat().st_size-size
        with path.open('r+b') as f:f.truncate(size)
        state['recoveredTailBytes']+=tail;state['resumes']+=1
    else:
        assert not path.exists(),'Unidentified result file'
        path.touch();save(cpfile,state,guard)
    guard.prior=state['coreSeconds'];guard.check();guard.watch()
    state.update(status='running',wallSaved=time.time())
    save(cpfile,state,guard)
    counts=C.Counter(state['counts']);buf=bytearray();pending=0;cursor=tuple(state['cursor']);reason='';finished=False
    out=path.open('ab')
    def commit(status,next_cursor,why=''):
        nonlocal buf,pending,state
        if buf:
            guard.check(len(buf));out.write(buf);out.flush();os.fsync(out.fileno());hasher.update(buf)
        state.update(status=status,count=state['count']+pending,cursor=list(next_cursor),coreSeconds=guard.seconds(),counts=dict(counts),prefixSHA256=hasher.hexdigest(),reason=why,wallSaved=time.time(),peakRSSBytes=max(state.get('peakRSSBytes',0),guard.peak_rss),peakArtifactBytes=max(state.get('peakArtifactBytes',0),guard.peak_disk))
        save(cpfile,state,guard,emergency=status=='paused');buf=bytearray();pending=0
    try:
        i,j=cursor
        while i<n-1:
            if j>=n:i+=1;j=i+1;continue
            a,b=atoms[i],atoms[j];current=(i,j);j+=1;cursor=(i,j)
            if a['parent']==b['parent'] or source_group(a,b) not in GROUPS[batch]:continue
            if (state['count']+pending)%512==0:guard.check()
            mask,valid,releases=result(a,b,data)
            buf.extend(RECORD.pack(i,current[1],mask.to_bytes(12,'little'),valid.to_bytes(12,'little'),*releases))
            pending+=1;counts[source_group(a,b)]+=1
            if pending>=chunk:
                previous=state['count'];commit('running',cursor)
                if state['count']//100000>previous//100000:
                    print(json.dumps(dict(batch=batch,count=state['count'],coreSeconds=round(guard.seconds(),3),peakRSSBytes=guard.peak_rss,artifactBytes=guard.peak_disk)),flush=True)
            if pause_after is not None and state['count']+pending>=pause_after:
                commit('paused',cursor,'requested-checkpoint-control');reason='requested-checkpoint-control';break
        else:finished=True
        if finished:
            if expected is not None:assert state['count']+pending==expected,(state['count']+pending,expected)
            commit('complete',(n-1,n))
        elif not reason:commit('paused',cursor,'interrupted')
    except LimitStop as e:
        # Discard uncommitted work; never enlarge artifacts after a limit fires.
        reason=str(e);buf.clear();pending=0
        state.update(status='paused',reason=reason,coreSeconds=guard.seconds(),wallSaved=time.time(),peakRSSBytes=max(state.get('peakRSSBytes',0),guard.peak_rss),peakArtifactBytes=max(state.get('peakArtifactBytes',0),guard.peak_disk))
        save(cpfile,state,guard,emergency=True)
    finally:
        out.close();guard.finish();lock.close()
    return state

def records(path):
    with Path(path).open('rb') as f:
        while block:=f.read(RECORD.size*16384):
            assert len(block)%RECORD.size==0
            yield from RECORD.iter_unpack(block)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('batch',choices=['A','B']);ap.add_argument('--pause-after',type=int);args=ap.parse_args()
    def interrupted(signum,frame):
        global SIGNAL_REASON
        SIGNAL_REASON='signal-'+str(signum);STOP.set()
    signal.signal(signal.SIGINT,interrupted);signal.signal(signal.SIGTERM,interrupted)
    protected=verify_sources();data=inputs();guard=Guard()
    identity=dict(batch=args.batch,expected=EXPECTED[args.batch],sources=protected,format=RECORD.format)
    directory=O/('batch-'+args.batch)
    state=pair_run(data,args.batch,directory,identity,guard,args.pause_after,EXPECTED[args.batch])
    for rel,h in protected.items():assert sha(R/rel)==h,rel
    save(directory/'sources.json',protected,guard,emergency=state['status']=='paused')
    print(json.dumps(state,ensure_ascii=False),flush=True)
    if state['status']!='complete':sys.exit(2)

if __name__=='__main__':main()
