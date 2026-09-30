#!/usr/bin/env python3
"""Historical predicate overlap, not v35 incremental strategy performance."""
import numpy as np
import h_entry_composite_p04_review as v
q,p=v.q,v.p
assert not(q.O/'completion.json').exists() and not(q.O/'rule-overlap.json').exists()
cat=q.read(p.P/'feature-catalog.json');names={x['name']:i for i,x in enumerate(cat)};masks={}
for label in ('discovery','later'):
 X,keys,rounds=p.dataset(label)
 def x(name):return X[:,names[name]]
 def finite(*fields):return np.isfinite(X[:,[names[n]for n in fields]]).all(axis=1)
 predicates={
 'HC-R02':finite('market_low_diff_125','market_ma_60_diff_max_9','market_kd_k_z_125','market_path_bottom')&(x('market_low_diff_125')>6.6)&(x('market_low_diff_125')<22)&(x('market_ma_60_diff_max_9')>0)&(x('market_kd_k_z_125')<.88)&(x('market_path_bottom')==0),
 # Only visible formula core; excluded maturity, missing fallback, actual
 # execution state and H-E01 precedence mean these are NOT executable counts.
 'H-E01-core':finite('market_path_bottom','market_path_late','market_kd_j_z_250','s_grade','ma60_diff')&(x('market_path_bottom')==1)&(x('market_path_late')==1)&(x('market_kd_j_z_250')>-.88)&((x('s_grade')>=1)|(x('ma60_diff')>-3.6)),
 'H-E02-core':finite('kd_d_z125','market_high_diff_250','intraday_high_diff','t_low_diff_z250')&(x('kd_d_z125')<-.85)&(x('market_high_diff_250')>-10)&(x('market_high_diff_250')<-1.7)&((x('intraday_high_diff')>2.2)|(x('t_low_diff_z250')<-.92))}
 for cid,m in predicates.items():masks[label,cid]={r['id']for r in rounds if m[r['entry']]}
out=[]
for fold in range(1,6):
 for node in q.read(q.O/f'fold-{fold}'/'review.json')['selected']:
  row=dict(id=node['id'],domains={})
  for domain,data in node['domains'].items():
   label='discovery'if domain in ('train','held')else'later';allowed={r['id']for r in data['baselineDetails']};hit={r['id']for r in data['baselineDetails']if r['hit']}
   row['domains'][domain]=[dict(id=cid,jaccard=v.jaccard(hit,masks[label,cid]&allowed),overlap=len(hit&masks[label,cid]),comparisonHits=len(masks[label,cid]&allowed))for cid in predicates]
  out.append(row)
q.save(q.O/'rule-overlap.json',dict(sources={name:p.sha(q.R/name) for name in ['doc/現行回測規則.md','doc/H-E01採用紀錄-20260929.md','doc/H-E02採用紀錄-20260930.md','doc/H買過早複合規則R02檢驗-20260929.md']},scope='v33 original H days only; H-E01/E02 formula-core overlap excludes execution guards, missing fallbacks and precedence; not current v35 marginal triggers',rows=out))
