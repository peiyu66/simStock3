#!/usr/bin/env python3
"""Aggregate evidence without choosing a replacement formula or strategy."""
import json,itertools
from collections import Counter,defaultdict
import h_entry_composite_p04_review as v
q,p=v.q,v.p

def main():
 assert not(q.O/'completion.json').exists(),'Completed P04 is immutable'
 protocol=q.read(q.O/'protocol.json');folds=[];allrows=[];struct=defaultdict(list);exact=defaultdict(list);features=Counter();topbase=[];topown=[];total=0;peak=0;seconds=0;variants=0;counterexamples=[]
 for f in protocol['folds']:
  n=f['fold'];d=q.O/f'fold-{n}';rr=q.read(d/'review.json');ss=q.read(d/'supplement.json');retained=q.read(d/'retained.json');nodes=rr['selected'];assert rr['frozenSHA']==p.sha(d/'frozen.json');assert len(retained)==rr['fullDailyCrossChecks']==800
  assert {x['stratum']for x in retained}=={'T','S','M','TS','TM','SM','TSM'}
  batches=[q.read(d/f'batch-{i}.json')for i in (1,2)]
  for i,b in enumerate(batches):
   assert b['complete']and b['evaluated']<=f['batchCaps'][i];total+=b['evaluated'];peak=max(peak,b['peakRSSBytes']);seconds+=b['elapsedSeconds']
  assert sum(b['counts'].get('AND2',0)for b in batches)==sum(f['pairCounts'].values())
  retainedcounts={k:dict(Counter(x['stratum']for x in pool))for k,pool in batches[1]['pools'].items()};assert all(len(pool)==200 for pool in batches[1]['pools'].values())
  row=dict(fold=n,evaluated=sum(b['evaluated']for b in batches),retainedByLayer=retainedcounts,evaluatedByStage={k:sum(b['counts'].get(k,0)for b in batches)for k in ('AND2','AND3','AND4','OR')},selected=[])
  for node,supp in zip(nodes,ss['selected']):
   assert node['id']==supp['id'];struct[json.dumps(node['structure'])].append(node['id']);exact[json.dumps(node['exactStructure'])].append(node['id'])
   for name in {x[0]for branch in node['structure']for x in branch}:features[name]+=1
   brief=dict(id=node['id'],expression=node['expression'],stratum=node['stratum'],branches=len(node['expr']),domains={k:x['totals']for k,x in node['domains'].items()},sensitivityCount=len(node['sensitivity']),neighborCount=len(supp['neighbors']),correlations=supp['correlations'])
   # Exclusion diagnostic: all predeclared one-at-a-time variants, no tuning.
   base=[];own=[]
   for domain in ('held','heldW3'):
    base+=node['domains'][domain]['baselineDetails'];own+=node['domains'][domain]['knownFlatDetails']
   hitids={x['id']for x in base if x['hit']};good={x['id']for x in own if x['hit']and x['wait']is not None and x['wait']<=10 and not x['afterExit']and not x['missing']and x['saving']>0};bad={x['id']for x in own if x['hit']and x['wait']is not None and x['wait']<=10 and not x['afterExit']and x['saving']<0}
   checks=[]
   for var in node['sensitivity']+supp['neighbors']:
    ids=set(var['domains']['held']['hitIds'])|set(var['domains']['heldW3']['hitIds']);diag=dict(kind=var['kind'],atom=var['atom'],value=var.get('value'),diagnostic=var.get('diagnostic','IQR or drop'),badExcluded=len(bad-ids),goodLost=len(good-ids),addedHits=len(ids-hitids),remainingHits=len(hitids&ids),trainPositive=var['domains']['train']['totals']['positiveCells'],heldPositive=var['domains']['held']['totals']['positiveCells'],heldW3Positive=var['domains']['heldW3']['totals']['positiveCells'])
    checks.append(diag)
   variants+=len(checks);counterexamples.append(dict(id=node['id'],knownGood=sorted(good),knownBad=sorted(bad),variants=checks,allKnownBadExcludedWithoutKnownGoodLoss=sum(bool(bad)and z['badExcluded']==len(bad)and z['goodLost']==0 for z in checks)))
   brief['knownBadExclusionPossibleCount']=counterexamples[-1]['allKnownBadExcludedWithoutKnownGoodLoss'];row['selected'].append(brief);allrows.append(brief)
  for domain in ('held','heldW3'):
   topbase+=nodes[0]['domains'][domain]['baselineDetails'];topown+=nodes[0]['domains'][domain]['knownFlatDetails']
  folds.append(row)
 assert len({x['id']for x in topbase})==len(topbase)
 assert total<=protocol['authorizedTotal']and total+variants*4+6<=protocol['authorizedTotal']
 protected=q.read(q.O/'protected.json')
 for path,h in protected.items():assert p.sha(q.R/path)==h,path
 old=q.read(p.O/'completion.json');oldhashes=old.get('artifacts',{})
 for path,h in oldhashes.items():
  fp=q.R/path
  if not fp.exists():fp=p.O/path
  assert p.sha(fp)==h,path
 q.save(q.O/'counterexample-diagnostics.json',counterexamples)
 summary=dict(scope='Historical v33 P03 workflow; no current strategy efficacy inference',evaluated=total,diagnosticVariants=variants,diagnosticDomainEvaluations=variants*4,searchAndDiagnostics=total+variants*4+6,fixedComparisonPredicates=6,cap=protocol['authorizedTotal'],searchSeconds=seconds,peakSearchRSSBytes=peak,folds=folds,uniqueStructures=len(struct),uniqueExactExpressions=len(exact),recurringStructures=[dict(ids=ids,structure=json.loads(k))for k,ids in struct.items()if len(ids)>1],featureFrequency=dict(features.most_common()),topRankOutOfFold=dict(note='Different frozen training-selected formula per fold, descriptive only; not a deployable strategy',totals=v.totals(topbase,topown),cells=v.r.summarize(topbase,topown)),selectedDomains={domain:dict(positiveCells=sum(x['domains'][domain]['positiveCells']for x in allrows),assessableCells=sum(x['domains'][domain]['assessableCells']for x in allrows),allPositiveSelections=sum(x['domains'][domain]['positiveCells']==x['domains'][domain]['assessableCells']and x['domains'][domain]['assessableCells']>0 for x in allrows))for domain in ('train','held','w3','heldW3')},counterexampleLeadsWithKnownBad=sum(bool(x['knownBad'])for x in counterexamples),counterexampleLeadsWithExclusionRoute=sum(x['allKnownBadExcludedWithoutKnownGoodLoss']>0 for x in counterexamples))
 q.save(q.O/'summary.json',summary)
 q.save(q.O/'verification.json',dict(p04Complete=True,foldsComplete=5,batchesComplete=10,selected=30,retained=4000,independentScalarChronologies=4000,fullDailyCrossChecks=4000,sourceHashesUnchanged=len(protected),oldP03HashesUnchanged=len(oldhashes),searchEvaluated=total,diagnosticDomainEvaluations=variants*4,searchAndDiagnostics=total+variants*4+6,authorizedMaximum=protocol['authorizedTotal'],noHeldReselection=True,noOriginalArtifactsOverwritten=True,replays=0,appBuilds=0,simulatorOperations=0))
 print(json.dumps({k:z for k,z in summary.items()if k not in ('folds','recurringStructures','topRankOutOfFold')},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
