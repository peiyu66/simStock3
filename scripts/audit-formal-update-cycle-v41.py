#!/usr/bin/env python3
"""Validate one v41 report against frozen P5, accounting, and v27 DecisionBase."""
import argparse, hashlib, importlib.util, json, sqlite3, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('p5_matrix_audit',ROOT/'scripts/summarize-update-cycle-matrix.py')
common=importlib.util.module_from_spec(spec);spec.loader.exec_module(common)
RULE='s51-update-cycle-se01-125x125-20261022'
def read(p):return json.loads(p.read_text())
def connect(p):
 db=sqlite3.connect(p.resolve().as_uri()+'?mode=ro',uri=True);db.row_factory=sqlite3.Row;return db

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--sample',required=True,choices=list('ABCDE'));p.add_argument('--window',required=True,choices=['fixed3y','fullstress']);p.add_argument('--rule-commit',required=True);a=p.parse_args()
 assert subprocess.check_output(['git','rev-parse',a.rule_commit+'^{commit}'],cwd=ROOT,text=True).strip()==a.rule_commit
 suffix='fixed' if a.window=='fixed3y' else 'full'
 rid=f'baseline-{a.sample.lower()}-v41-s51-update-cycle-t4s65-9y-{a.window}-600w-20261022'
 d=ROOT/'exports/backtest-reports'/rid;b=read(d/'baseline.json');m=read(d/'manifest.json')
 p5run='p5-maturity-a-fixed-03' if a.sample=='A' and suffix=='fixed' else f'p5-{a.sample.lower()}-{suffix}-01'
 prior=ROOT/'exports/update-cycle-p5'/p5run/'report';old=read(prior/'baseline.json')
 protected={}
 def protect(p):protected[str(p.resolve())]=common.sha(p)
 for root in [d,prior]:
  for f in root.iterdir():
   if f.name.endswith(('.store','.store-wal')) or f.name in ['baseline.json','manifest.json','periods.csv']:protect(f)
 assert (d/'.complete').read_text().strip()==rid
 for v in [b,m]:
  assert v['ruleCommit']==a.rule_commit and v['dataRuleVersion']=='T4/S65' and v['ruleVersion']==RULE
  assert not v.get('diagnostic')
  for key in ['sampleID','historyStart','through','moneyBaseWan','automaticInvestments','periodStarts']:assert v[key]==old[key],key
 assert b['marketInput']['marketTechnicalVersion']=='7'
 for key in ['combinedScore','stocks','groups','periods']:assert b[key]==old[key],key
 assert (d/'periods.csv').read_bytes()==(prior/'periods.csv').read_bytes()
 html=(d/'report.html').read_text();assert a.rule_commit in html and 'T4/S65' in html
 assert f'baseline-{a.sample.lower()}-v40-s50-resumable-update' in html
 if a.sample=='B':assert '與同版 Baseline A 的比較解讀' in html and '找不到同版 Baseline A' not in html
 for f in m['reportFiles']:assert (d/f).is_file(),f
 checks=[];days=0
 for start in b['periodStarts']:
  newstore=common.store_for(d,b,start);oldstore=common.store_for(prior,old,start)
  with connect(newstore) as db,connect(oldstore) as prev:
   assert db.execute('pragma integrity_check').fetchone()[0]=='ok'
   cols=[r['name'] for r in db.execute('pragma table_info(ZTRADE)') if r['name'] not in ['Z_PK','Z_ENT','Z_OPT','ZSTOCK']]
   q='SELECT s.ZSID,'+','.join('t.'+x for x in cols)+' FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK ORDER BY s.ZSID,t.ZDATETIME'
   n=0
   for x,y in zip(db.execute(q),prev.execute(q),strict=True):
    assert tuple(x)==tuple(y),(start,n,'persisted fields differ from frozen P5')
    n+=1
   checks.append(dict(period=start,persistedRows=n,allTradeFieldsExactlyEqualP5=True))
 for stock in b['stocks']:
  assert stock['targetValidity']=='target-period-valid'
  prev,rows=common.read_rows(common.store_for(d,b,stock['periodStart']),stock['id'],stock['effectiveSimulationStart'],stock['periodEnd'])
  ledger=common.audit(rows,prev,b['moneyBaseWan']*10000);days+=ledger['days']
  checks.append(dict(stock=stock['id'],period=stock['periodStart'],accounting=ledger))
 result=dict(status='passed',runID=rid,ruleCommit=a.rule_commit,simulationDays=days,combinedScore=b['combinedScore'],p5Exact=True,checks=checks,sources=protected)
 if a.window=='fixed3y':
  profile='abcde9-v3' if a.sample=='E' else 'abcd9-v3';bid=f'{a.sample.lower()}-{profile}-{RULE}-t4-s65-{a.rule_commit[:12]}-fixed3y-20260722-v27'
  base=ROOT/'exports/backtest-decision-bases'/bid;bm=read(base/'manifest.json')
  assert bm['ruleCommit']==a.rule_commit and bm['dataRuleVersion']=='T4/S65' and bm['ruleVersion']==RULE
  assert bm['formatVersion']==6 and bm['stockCount']==10 and bm['windowCount']==3 and bm['outcomeCount']==30
  assert bm['marketTechnicalVersion']==7
  for marker in ['.complete','.p4b-complete']:assert (base/marker).read_text().strip()==bid
  with connect(base/'decisions.sqlite') as db:
   assert db.execute('pragma integrity_check').fetchone()[0]=='ok'
   meta=dict(db.execute('select key,value from metadata'))
   assert meta['ruleCommit']==a.rule_commit and meta['dataRuleVersion']=='T4/S65' and meta['ruleVersion']==RULE
   assert meta['marketTechnicalVersion']=='7'
   assert db.execute('select count(*) from rules').fetchone()[0]==99
   events=db.execute('select count(*) from decision_events').fetchone()[0];assert events==bm['eventCount'] and events>0
  result['decisionBase']=dict(id=bid,eventCount=events,p4bPassed=True,format=6)
  for f in base.rglob('*'):
   if f.is_file():protect(f)
 assert all(common.sha(Path(f))==h for f,h in protected.items())
 out=ROOT/'exports/update-cycle-p6'/f'p6-{a.sample.lower()}-{a.window}'/'audit.json';out.write_text(json.dumps(result,ensure_ascii=False,indent=2))
 print(json.dumps({k:v for k,v in result.items() if k not in ['checks','sources']},ensure_ascii=False),flush=True)
if __name__=='__main__':main()
