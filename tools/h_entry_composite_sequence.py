#!/usr/bin/env python3
"""HC-R chronological analysis. Price proxies are never simulated fills or ROI."""
import json,sys,hashlib,struct,time
from pathlib import Path
from collections import Counter
import numpy as np
import h_entry_composite as h
R=Path(__file__).resolve().parents[1];OLD=R/'exports/h-entry-composite-20260923';OUT=R/'exports/h-entry-composite-reanalysis-20260928'
def read(p):return json.loads(p.read_text())
def save(n,x):
 p=OUT/n;p.write_text(json.dumps(x,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
def data(label):return np.load(OLD/f'{label}.npz')['X'],read(OLD/f'{label}-keys.json'),read(OLD/f'{label}-rounds.json')
def is_s(a):return a['name'].startswith(('s_','delta_s_'))
def details(expr,X,keys,rounds,atoms,qualified=False):
 sig,valid=h.eval_expr(expr,atoms,X);out=[]
 for r in rounds:
  b,e=r['entry'],r['end'];hit=bool(sig[b]);release=None
  if hit:
   release=next((i for i in range(b+1,e+1)if not sig[i]and(not qualified or keys[i]['h_score']>=keys[i]['h_threshold'])),None)
  price=keys[release]['close']if release is not None else None
  # Missing output has no hypothetical purchase or benefit credited.
  gain=(100*(1-price/r['entry_price'])if price is not None else -max(100*(keys[e]['close']/r['entry_price']-1),0))if hit else 0.
  out.append(dict(id=r['id'],sample=r['sample'],window=r['window'],stock=r['stock'],kind=r['kind'],opportunity=r['opportunity'],censored=r['censored'],hit=hit,release=keys[release]['date']if release is not None else None,entryDate=r['entry_date'],entryPrice=r['entry_price'],releasePrice=price,gain=gain,clippedGain=float(np.clip(gain,-10,10)),wait=release-b if release is not None else None,noRelease=hit and release is None,releaseMissing=release is not None and not bool(valid[release]),beforeDecline=release is not None and r['decline']is not None and release<r['decline']))
 return out

def summary(rows):
 out={}
 for cell in sorted({f'{x["sample"]}{x["window"]}'for x in rows}):
  rs=[x for x in rows if f'{x["sample"]}{x["window"]}'==cell];hits=[x for x in rs if x['hit']];rel=[x for x in hits if x['release']is not None];targets=[x for x in hits if x['opportunity']]
  out[cell]=dict(entries=len(rs),hits=len(hits),stocks=len({x['stock']for x in hits}),targets=len(targets),meanAll=sum(x['gain']for x in rs)/len(rs),clippedMeanAll=sum(x['clippedGain']for x in rs)/len(rs),cheaper=sum(x['gain']>0 for x in rel),dearer=sum(x['gain']<0 for x in rel),equal=sum(x['gain']==0 for x in rel),noRelease=sum(x['noRelease']for x in hits),missingRelease=sum(x['releaseMissing']for x in hits),medianWait=float(np.median([x['wait']for x in rel]))if rel else None,p90Wait=float(np.quantile([x['wait']for x in rel],.9))if rel else None,targetEarlyRelease=sum(x['beforeDecline']for x in targets),targetCheaper=sum(x['releasePrice']is not None and x['gain']>0 for x in targets),otherGain=sum(x['gain']for x in hits if not x['opportunity']),targetGain=sum(x['gain']for x in targets),censoredHits=sum(x['censored']for x in hits))
 return out

def prepare():
 for dirname in ['h-entry-composite-20260923','h-entry-composite-ab-20260928']:
  c=read(R/'exports'/dirname/'completion.json')
  for f,v in c['artifacts'].items():assert h.sha(R/f)==v,f
 X,keys,rounds=data('discovery');atoms=read(OLD/'atoms.json');usable=[a for a in atoms if not is_s(a)];N=len(rounds);A=len(usable)
 H=np.zeros((A,N),dtype=np.uint8);F=np.zeros((A,N),dtype=np.int32);G=np.zeros((A,N),dtype=np.float64)
 for j,a in enumerate(usable):
  sig,val=h.atom_array(a,X)
  for k,r in enumerate(rounds):
   b,e=r['entry'],r['end'];H[j,k]=sig[b];ix=np.flatnonzero(~sig[b+1:e+1]);f=b+1+int(ix[0])if len(ix)else e+1;F[j,k]=f
   G[j,k]=np.clip(100*(1-keys[f]['close']/r['entry_price'])if f<=e else -max(100*(keys[e]['close']/r['entry_price']-1),0),-10,10)
 groups=np.array([('A','B').index(r['sample'])*2+r['window']-1 for r in rounds],dtype=np.int32)
 stocks=sorted({r['stock']for r in rounds});stockbits=np.array([1<<stocks.index(r['stock'])for r in rounds],dtype=np.uint32)
 parents=sorted({a['parent']for a in usable})
 with(OUT/'search-input.bin').open('wb')as f:
  f.write(struct.pack('ii',A,N));np.array([a['id']for a in usable],dtype=np.int32).tofile(f);np.array([parents.index(a['parent'])for a in usable],dtype=np.int32).tofile(f);groups.tofile(f);stockbits.tofile(f);H.tofile(f);F.tofile(f);G.tofile(f)
 save('preflight.json',dict(sourceArtifactsVerified=155,atoms=A,rounds=N,excludedSAtoms=len(atoms)-A,sourceSHA={str(p.relative_to(R)):h.sha(p)for p in [OLD/'atoms.json',OLD/'discovery.npz',OLD/'discovery-keys.json',OLD/'discovery-rounds.json',OUT/'protocol.json']}))
 old=read(OLD/'search-retained.json');audit=[]
 for i,r in enumerate(old):
  s=summary(details(r['expr'],X,keys,rounds,atoms));audit.append(dict(expression=r['expression'],expr=r['expr'],hasS=any(is_s(atoms[a])for b in r['expr']for a in b),cells=s,positiveAll=all(v['clippedMeanAll']>0 for v in s.values())))
 save('retained-review.json',audit)
 print('PREPARED',A,'atoms',N,'rounds; retained',len(old),'all-positive T-only',sum(x['positiveAll']and not x['hasS']for x in audit),flush=True)

def freeze():
 assert not(OUT/'frozen.json').exists()
 X,keys,rounds=data('discovery');atoms=read(OLD/'atoms.json');raw=read(OUT/'search-results.json');chosen=[];masks=[]
 for r in raw['nodes']:
  expr=[r['atoms']];sig,_=h.eval_expr(expr,atoms,X);mask=np.array([sig[x['entry']]for x in rounds]);
  if any((mask&m).sum()/max(1,(mask|m).sum())>=.75 for m in masks):continue
  ss=summary(details(expr,X,keys,rounds,atoms));assert all(v['clippedMeanAll']>0 and v['hits']>=10 and v['stocks']>=5 for v in ss.values())
  chosen.append(dict(id=f'HC-R{len(chosen)+1:02}',expr=expr,expression=h.format_expr(expr,atoms),cells=ss,discoveryScore=r['worst']));masks.append(mask)
  if len(chosen)==6:break
 save('frozen.json',dict(knownW3=True,selection='W1/W2 chronology only',candidates=chosen,inputSHA=h.sha(OUT/'search-input.bin'),searchSHA=h.sha(OUT/'search-results.json')))
 print('FROZEN',[(x['id'],x['expression'])for x in chosen],flush=True)

def review():
 atoms=read(OLD/'atoms.json');cs=read(OUT/'frozen.json')['candidates'];out=[]
 for label in ['discovery','later']:
  X,keys,rounds=data(label)
  for c in cs+read(OLD/'frozen-candidates.json')['candidates']:
   raw=details(c['expr'],X,keys,rounds,atoms);qualified=details(c['expr'],X,keys,rounds,atoms,True)
   out.append(dict(candidate=c['id'],label=label,cells=summary(raw),baselineQualificationSensitivity=summary(qualified),detail=raw,qualificationDetail=qualified))
 save('chronology-review.json',out)
 print('Chronology review complete; raw releases and original-path H sensitivity kept separate',flush=True)

if __name__=='__main__':
 assert not (OUT/'completion.json').exists(),'Completed output is immutable; use a separate output directory for reproduction'
 globals()[sys.argv[1]]()
