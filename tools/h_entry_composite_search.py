#!/usr/bin/env python3
"""Bounded composite generation. Real outcome ranking is supplied by a future authorized caller.
P02 exercises this engine ONLY on synthetic planted data.
"""
from dataclasses import dataclass
from collections import Counter,defaultdict
import itertools,math
import numpy as np
STRATA=('T','S','M','TS','TM','SM','TSM')
def group_key(groups):return ''.join(g for g in 'TSM' if g in groups)
def bits(a):return int.from_bytes(np.packbits(a,bitorder='little').tobytes(),'little')
def coarse(v):return float(f'{v:.2g}') if v else 0.
@dataclass(frozen=True)
class Atom:
 id:int
 name:str
 parent:str
 group:str
 op:str
 value:object
 mask:int
 valid:int
 @property
 def comparisons(self):return 2 if self.op=='between' else 1

def make_atoms(X,cat):
 out=[]
 for j,c in enumerate(cat):
  column=X[:,j];ok=np.isfinite(column);v=column[ok]
  if not len(v):continue
  defs=[]
  if c['kind']=='boolean':defs=[('eq',0.),('eq',1.)]
  elif c['kind']=='category':defs=[(op,float(x)) for x in c['values'] for op in ('eq','ne')]
  elif c['kind']=='grade':defs=[(op,x) for x in (-2.5,-1.5,.5,1.5,2.5) for op in ('lt','gt')]
  else:
   cuts={coarse(float(np.quantile(v,q))) for q in (.25,.5,.75)}
   if min(v)<0<max(v):cuts.add(0.)
   defs=[(op,x) for x in sorted(cuts) for op in ('lt','gt')]
   lo,hi=(coarse(float(np.quantile(v,q))) for q in (.25,.75))
   if lo<hi:defs.append(('between',(lo,hi)))
  seen=set();valid=bits(ok)
  for op,val in defs:
   m=ok & ({'lt':lambda:column<val,'gt':lambda:column>val,'eq':lambda:column==val,'ne':lambda:column!=val,'between':lambda:(column>val[0])&(column<val[1])}[op]())
   mask=bits(m)
   if mask==0 or mask==valid or mask in seen:continue
   seen.add(mask);out.append(Atom(len(out),c['name'],c['parent'],c['group'],op,val,mask,valid))
 return out
@dataclass
class Node:
 expr:tuple
 mask:int
 valid:int
 stratum:str
 score:tuple

def make_node(expr,atoms,rank):
 expr=tuple(sorted(tuple(sorted(b)) for b in expr));parents={atoms[i].parent for b in expr for i in b}
 if len(expr)>2 or not 2<=len(parents)<=4:return None
 if any(len({atoms[i].parent for i in b})!=len(b) or len(b)<2 for b in expr):return None
 if sum(atoms[i].comparisons for b in expr for i in b)>8:return None
 valid=None;mask=0
 for b in expr:
  bm=None
  for i in b:
   a=atoms[i];bm=a.mask if bm is None else bm&a.mask;valid=a.valid if valid is None else valid&a.valid
  mask|=bm
 mask&=valid
 stratum=group_key({atoms[i].group for b in expr for i in b});score=rank(mask,valid)
 return Node(expr,mask,valid,stratum,score)

def choose(candidates,width=200,reserve=25):
 by=defaultdict(list)
 for n in candidates:by[n.stratum].append(n)
 order=lambda n:(n.score,tuple(-i for b in n.expr for i in b))
 picked=[];seen=set()
 def take(seq,limit):
  added=0
  for n in sorted(seq,key=order,reverse=True):
   k=(n.mask,n.valid)
   if k in seen:continue
   seen.add(k);picked.append(n);added+=1
   if added>=limit or len(picked)>=width:return
 for s in STRATA:
  if len(picked)<width:take(by[s],min(reserve,width-len(picked)))
 if len(picked)<width:take(candidates,width-len(picked))
 return picked
class Reservoir:
 """Bounded unique masks separately per source stratum, before global selection."""
 def __init__(self,limit=400):self.by=defaultdict(dict);self.limit=limit
 def add(self,n):
  if n is None:return
  d=self.by[n.stratum];key=(n.mask,n.valid);old=d.get(key)
  if old is None or n.score>old.score:d[key]=n
  if len(d)>2*self.limit:
   self.by[n.stratum]=dict(sorted(d.items(),key=lambda kv:kv[1].score,reverse=True)[:self.limit])
 def values(self):return [n for d in self.by.values() for n in d.values()]

def search(X,cat,rank,width=200,reserve=25,cap=2000000):
 atoms=make_atoms(X,cat);counts=Counter();by_source=defaultdict(Counter);reservoir=Reservoir(max(400,width*2))
 def consider(expr,stage,dest):
  n=make_node(expr,atoms,rank)
  if n is None:return
  counts[stage]+=1
  if sum(counts.values())>cap:raise RuntimeError('authorized condition budget exceeded')
  by_source[stage][n.stratum]+=1;dest.add(n)
 for i,a in enumerate(atoms):
  for b in atoms[i+1:]:
   if a.parent!=b.parent:consider(((a.id,b.id),),'AND2',reservoir)
 pair_pool=choose(reservoir.values(),width,reserve);beam=pair_pool;all_nodes=list(beam)
 for depth in (3,4):
  dest=Reservoir(max(400,width*2));seen=set()
  for n in beam:
   b=n.expr[0];parents={atoms[i].parent for i in b}
   for a in atoms:
    if a.parent in parents:continue
    expr=(tuple(sorted((*b,a.id))),)
    if expr in seen:continue
    seen.add(expr);consider(expr,'AND'+str(depth),dest)
  beam=choose(dest.values(),width,reserve);all_nodes+=beam
 # OR must originate in the pair pool, not only terminal 4-field branches.
 dest=Reservoir(max(400,width*2))
 for i,a in enumerate(pair_pool):
  for b in pair_pool[i+1:]:
   if len({atoms[t].parent for branch in a.expr+b.expr for t in branch})>4:continue
   if a.mask|b.mask in (a.mask,b.mask):continue
   consider(a.expr+b.expr,'OR',dest)
 ors=choose(dest.values(),width,reserve);all_nodes+=ors
 return atoms,all_nodes,dict(counts),{k:dict(v) for k,v in by_source.items()}
