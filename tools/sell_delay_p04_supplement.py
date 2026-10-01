import sys
sys.path.insert(0,'tools')
import sell_delay_p04 as q
import numpy as np
from collections import Counter
O=q.O
assert not (O/'bounded-field-sensitivity.json').exists()
fs=q.read(q.p.O/'frozen-families.json')['families'];defs=q.read(q.P/'atoms-no-outcome-ranking.json');rows=[]
for label in ['discovery','later']:
 c=q.Context(label)
 for fi,name in [(0,'market_high_diff_z_250'),(3,'holding_cost_before')]:
  f=fs[fi];e=q.canon(f['expr']);old=next(i for b in e for i in b if defs[i]['name']==name)
  for a in defs:
   if a['name']!=name or a['id']==old:continue
   ex=q.canon([[a['id']if i==old else i for i in b]for b in e]);rows.append(dict(family=f['family'],partition=label,expr=ex,expression=q.p.expression(ex,defs),metrics=c.evaluate(ex,c.outcomes(e)[0]),W3UsedForDiagnosis=True,noFurtherOptimization=True))
q.save('bounded-field-sensitivity.json',rows)
# Period comparisons of all 292 values at retrospective peaks are descriptive, never usable as causal rule inputs.
peaks=[]
for label in ['discovery','later']:
 c=q.Context(label)
 for f in fs:
  st=c.outcomes(f['expr'])[0];cols=[]
  for j,col in enumerate(c.cat):
   items={}
   for name,which in [('opportunity',lambda k:bool(c.pos[k])),('counterexample',lambda k:bool(c.neg[k]or st[k]==2))]:
    idx=[i for k,o in enumerate(c.ops)if st[k]and which(k)for i in o['indices'][1:]if c.keys[i]['date']in o['highestDates']]
    x=c.X[idx,j];x=x[np.isfinite(x)];items[name]=dict(knownPeakRows=len(x),median=float(np.median(x))if len(x)else None,min=float(np.min(x))if len(x)else None,max=float(np.max(x))if len(x)else None)
   cols.append(dict(name=col['name'],group=col['group'],values=items))
  peaks.append(dict(family=f['family'],partition=label,columns=cols,retrospectiveOnly=True))
q.save('peak-field-contrasts.json',peaks)
for r in rows:
 if r['family']=='SD-F04':print(r['partition'],r['expression'],r['metrics']['positive'],r['metrics']['negative'],r['metrics']['comparison'])
q.save('recovery.json',dict(stage='existing-rule-overlap',error='SQLite no such column: rule_id',cause='event_votes stores rule_key, identifier belongs to rules',fix='join event_votes to rules USING(rule_key); read-only rerun only overlap',verified=True,noSearchRerun=True))
