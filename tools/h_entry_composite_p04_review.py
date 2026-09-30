#!/usr/bin/env python3
"""Frozen P04 diagnostic review; does not select or replay strategies."""
import copy, json, sys
from collections import Counter
import numpy as np
import h_entry_composite_p04 as q
p,e,r=q.p,q.e,q.review

def inputs(defs,label):
 X,keys,rounds=p.dataset(label);cat=q.read(p.P/'feature-catalog.json')
 C=np.load(p.P/'candidate-flat.npz')['X'];ck=q.read(p.P/'candidate-flat-keys.json');windows={1,2}if label=='discovery'else{3}
 ix=[i for i,k in enumerate(ck)if k['window']in windows];C=C[ix];ck=[ck[i]for i in ix]
 flat=[x for x in q.read(p.SW/'unique-flat-paths.json')if x['window']in windows]
 return (keys,rounds,list(p.arrays(defs,X,cat)),flat,list(p.arrays(defs,C,cat)),{(k['anchor'],k['date']):i for i,k in enumerate(ck)}),X,C

def subset(data,stocks):
 keys,rounds,am,flat,cm,lookup=data
 return keys,[x for x in rounds if x['stock']in stocks],am,[x for x in flat if x['stock']in stocks],cm,lookup

def totals(base,own):
 cells=r.summarize(base,own);h=[x for x in base if x['hit']];ch=[x for x in own if x['hit']]
 f=[x for x in ch if x['wait']is not None and x['wait']<=10 and not x['afterExit']]
 stocks=Counter(x['stock']for x in h);dates=Counter(x['entryDate']for x in h)
 return dict(hits=len(h),targetHits=sum(x['target']for x in h),controlHits=sum(x['control']for x in h),positiveCells=sum(x['enrichment']is not None and x['enrichment']>0 for x in cells.values()),assessableCells=sum(x['enrichment']is not None for x in cells.values()),enrichment={c:x['enrichment']for c,x in cells.items()},knownHits=len(ch),unknownPathHits=len(h)-len(ch),knownFills10=len(f),knownCheaper10=sum(x['saving']>0 and not x['missing']for x in f),knownDearer10=sum(x['saving']<0 for x in f),knownEqual10=sum(x['saving']==0 for x in f),knownUnresolved10=len(ch)-len(f),knownProper10=sum(x['saving']>0 and not x['early']and not x['missing']for x in f if x['target']),knownEarly10=sum(x['early']for x in f if x['target']),knownAfterExit=sum(x['afterExit']for x in ch),rawProper10=sum(x['horizons'][10]['rawTargetProper']for x in cells.values()),maxStockShare=max(stocks.values(),default=0)/max(1,len(h)),maxDateShare=max(dates.values(),default=0)/max(1,len(h)),stockHits=dict(stocks),sameDateHits={str(k):v for k,v in dates.items()if v>1})

def variant_specs(expr,defs,X,cat,trainix):
 lookup={x['name']:i for i,x in enumerate(cat)}
 for atom in sorted({i for b in expr for i in b}):
  yield dict(kind='drop',atom=atom,expr=[[i for i in b if i!=atom]for b in expr])
  a=defs[atom];j=lookup[a['name']]
  if cat[j]['kind']!='continuous':continue
  v=X[trainix,j];v=v[np.isfinite(v)];iqr=float(np.quantile(v,.75)-np.quantile(v,.25))
  for sign in (-1,1):
   old=a['value'];new=[e.coarse(float(x)+sign*.1*iqr)for x in old]if isinstance(old,list)else e.coarse(old+sign*.1*iqr)
   if isinstance(new,list)and new[0]>=new[1]:continue
   yield dict(kind='cut',atom=atom,expr=expr,deltaIQR=sign*.1,value=new,unchanged=new==old)

def changed_data(data,X,C,defs,cat,spec):
 if spec['kind']=='drop':return data
 am=list(data[2]);cm=list(data[4]);a=dict(defs[spec['atom']],value=spec['value'])
 am[spec['atom']]=next(p.arrays([a],X,cat));cm[spec['atom']]=next(p.arrays([a],C,cat))
 return data[0],data[1],am,data[3],cm,data[5]

def jaccard(a,b):return len(a&b)/max(1,len(a|b))
def structure(expr,defs,values=False):
 return sorted(sorted((defs[i]['name'],defs[i]['op'],json.dumps(defs[i]['value'])if values else '')for i in b)for b in expr)

def run(fold):
 d=q.O/f'fold-{fold}';assert not(d/'review.json').exists()
 frozen=q.read(d/'frozen.json');frozenhash=p.sha(d/'frozen.json');spec=q.read(q.O/'protocol.json')['folds'][fold-1];defs=q.read(d/'atoms.json');cat=q.read(p.P/'feature-catalog.json')
 ds,X,C=inputs(defs,'discovery');later,Y,D=inputs(defs,'later');trainix=[i for i,k in enumerate(ds[0])if k['stock']in spec['trainStocks']]
 domains=dict(train=(subset(ds,spec['trainStocks']),X,C),held=(subset(ds,spec['heldStocks']),X,C),w3=(later,Y,D),heldW3=(subset(later,spec['heldStocks']),Y,D))
 # Every retained rank is checked against a full original daily walk, separately
 # from the bitset/scalar compact ranking checks performed by search.
 for i,node in enumerate(q.read(d/'retained.json')):
  bb,oo=r.details(node['expr'],domains['train'][0]);t=totals(bb,oo);z=node['metrics']
  assert t['hits']==z['hits']and t['rawProper10']==z['rawProper10']
  assert t['knownCheaper10']==z['knownProperCheaper10']
 print('DAILY CROSSCHECK',fold,i+1,flush=True)
 old=q.read(p.O/'review.json');outputs=[]
 for number,node in enumerate(frozen['selected'],1):
  cid=f'P04-F{fold}-{number:02}';variants=list(variant_specs(node['expr'],defs,X,cat,trainix));out=dict(id=cid,expression=node['expression'],expr=node['expr'],stratum=node['stratum'],structure=structure(node['expr'],defs),exactStructure=structure(node['expr'],defs,True),domains={},sensitivity=[])
  for name,(data,xx,cc)in domains.items():
   bb,oo=r.details(node['expr'],data);branches=[]
   for b in node['expr']:
    xb,xo=r.details([b],data);branches.append(dict(expr=[b],totals=totals(xb,xo),cells=r.summarize(xb,xo)))
   hitids={x['id']for x in bb if x['hit']};allowed={x['id']for x in bb};oldrows=[x for x in old if x['label']==('discovery'if name in ('train','held')else'later')]
   comparisons=[]
   for prev in oldrows:
    ph={x['id']for x in prev['baselineDetails']if x['hit']and x['id']in allowed}
    comparisons.append(dict(id=prev['id'],jaccard=jaccard(hitids,ph),overlap=len(hitids&ph),previousHits=len(ph)))
   out['domains'][name]=dict(totals=totals(bb,oo),cells=r.summarize(bb,oo),baselineDetails=bb,knownFlatDetails=oo,branches=branches,p03Overlap=comparisons)
  for variant in variants:
   result=dict(**variant,domains={})
   for name,(data,xx,cc)in domains.items():
    dd=changed_data(data,xx,cc,defs,cat,variant);bb,oo=r.details(variant['expr'],dd);result['domains'][name]=dict(totals=totals(bb,oo),cells=r.summarize(bb,oo),hitIds=[x['id']for x in bb if x['hit']])
   out['sensitivity'].append(result)
  outputs.append(out);print('REVIEW',cid,'variants',len(variants),flush=True)
 assert p.sha(d/'frozen.json')==frozenhash
 q.save(d/'review.json',dict(fold=fold,frozenSHA=frozenhash,noReselection=True,fullDailyCrossChecks=i+1,selected=outputs))

if __name__=='__main__':run(int(sys.argv[1]))
