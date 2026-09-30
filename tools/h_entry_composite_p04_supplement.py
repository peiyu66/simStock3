#!/usr/bin/env python3
"""Plan-required adjacent coarse cuts, old-rule overlap and collinearity."""
import itertools,sys
import numpy as np
import h_entry_composite_p04_review as v
q,p,e,r=v.q,v.p,v.e,v.r

def neighbors(expr,defs):
 for aid in sorted({i for b in expr for i in b}):
  a=defs[aid]
  if a['op']not in ('lt','gt','between'):continue
  cuts=sorted({float(x['value'])for x in defs if x['name']==a['name']and x['op']in ('lt','gt')})
  vals=a['value']if a['op']=='between'else[a['value']]
  for coordinate,value in enumerate(vals):
   below=[x for x in cuts if x<value];above=[x for x in cuts if x>value]
   for adjacent in (below[-1:] + above[:1]):
    new=list(vals);new[coordinate]=adjacent
    if a['op']=='between'and new[0]>=new[1]:continue
    yield dict(kind='cut',atom=aid,expr=expr,coordinate=coordinate,value=new if a['op']=='between'else new[0],before=a['value'],diagnostic='adjacent training-generated coarse cutoff')

def run(fold):
 d=q.O/f'fold-{fold}';assert not(d/'supplement.json').exists();f=q.read(q.O/'protocol.json')['folds'][fold-1];defs=q.read(d/'atoms.json');cat=q.read(p.P/'feature-catalog.json');review=q.read(d/'review.json')
 ds,X,C=v.inputs(defs,'discovery');later,Y,D=v.inputs(defs,'later');domains=dict(train=(v.subset(ds,f['trainStocks']),X,C),held=(v.subset(ds,f['heldStocks']),X,C),w3=(later,Y,D),heldW3=(v.subset(later,f['heldStocks']),Y,D));columns={x['name']:i for i,x in enumerate(cat)}
 ix=[i for i,k in enumerate(ds[0])if k['stock']in f['trainStocks']];old={}
 for label in ('discovery','later'):
  for cid in ('HC-D01','HC-D02','HC-D03','HC-D04','HC-D05','HC-D06'):
   rows=q.read(p.OLD/f'{label}-{cid}-cases.json');old[label,cid]={x['id']for x in rows if x['entryHit']}
 outputs=[]
 for node in review['selected']:
  expr=node['expr'];out=dict(id=node['id'],neighbors=[],correlations=[],oldRuleOverlap={})
  for spec in neighbors(expr,defs):
   result=dict(**spec,domains={})
   for name,(data,xx,cc)in domains.items():
    bb,oo=r.details(expr,v.changed_data(data,xx,cc,defs,cat,spec));result['domains'][name]=dict(totals=v.totals(bb,oo),cells=r.summarize(bb,oo),hitIds=[x['id']for x in bb if x['hit']])
   out['neighbors'].append(result)
  names=sorted({defs[i]['name']for b in expr for i in b})
  for a,b in itertools.combinations(names,2):
   z=X[ix][:,[columns[a],columns[b]]];z=z[np.isfinite(z).all(axis=1)];rho=float(np.corrcoef(z.T)[0,1])if len(z)>1 and (np.std(z,axis=0)>0).all()else None
   out['correlations'].append(dict(first=a,second=b,trainingRows=len(z),pearson=rho))
  for name,domain in node['domains'].items():
   allowed={x['id']for x in domain['baselineDetails']};hits={x['id']for x in domain['baselineDetails']if x['hit']};label='discovery'if name in ('train','held')else'later'
   out['oldRuleOverlap'][name]=[dict(id=cid,jaccard=v.jaccard(hits,old[label,cid]&allowed),overlap=len(hits&old[label,cid]),oldHits=len(old[label,cid]&allowed))for cid in ('HC-D01','HC-D02','HC-D03','HC-D04','HC-D05','HC-D06')]
  outputs.append(out)
 q.save(d/'supplement.json',dict(fold=fold,purpose='Plan-required coarse neighbors and mechanism overlap; descriptive only, no reselection',selected=outputs));print('SUPPLEMENT',fold,'neighbors',sum(len(x['neighbors'])for x in outputs),flush=True)
if __name__=='__main__':run(int(sys.argv[1]))
