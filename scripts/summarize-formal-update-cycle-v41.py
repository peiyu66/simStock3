#!/usr/bin/env python3
"""Freeze the accepted v41 matrix without changing P5/E1/v40 or publishing."""
import argparse,csv,hashlib,json,subprocess
from datetime import datetime,timezone
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def read(p):return json.loads(p.read_text())
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--rule-commit',required=True);a=p.parse_args()
 assert subprocess.check_output(['git','rev-parse',a.rule_commit+'^{commit}'],cwd=ROOT,text=True).strip()==a.rule_commit
 target=ROOT/'exports/update-cycle-p6';assert not (target/'completion.json').exists(),'Preserve the previous acceptance evidence'
 rows=[];sources={};days=stored=0;databases=[];peak=0
 def protect(path):
  if path.is_file():sources[str(path.resolve())]=sha(path)
 for sample in 'ABCDE':
  for window in ['fixed3y','fullstress']:
   run=target/f'p6-{sample.lower()}-{window}';summary=read(run/'summary.json');audit=read(run/'audit.json')
   assert summary['status']==audit['status']=='passed' and summary['ruleCommit']==audit['ruleCommit']==a.rule_commit
   assert audit['p5Exact'] and summary['combinedScore']==audit['combinedScore']
   report=Path(summary['report']).parent;b=read(report/'baseline.json');m=read(report/'manifest.json')
   assert b['ruleCommit']==m['ruleCommit']==a.rule_commit and b['dataRuleVersion']==m['dataRuleVersion']=='T4/S65'
   assert b['ruleVersion']==m['ruleVersion']=='s51-update-cycle-se01-125x125-20261022'
   assert b['marketInput']['marketTechnicalVersion']==m['marketInput']['marketTechnicalVersion']=='7'
   # Runner records the exact staged reference source in the original project.
   reference=Path('/Users/peiyu/Developer/simStock3/exports/backtest-reports')/f'baseline-{sample.lower()}-v40-s50-resumable-update-t3s64-9y-{window}-600w-20261016'/'baseline.json'
   old=read(reference);protect(reference)
   rows.append(dict(sample=sample,window=window,score=b['combinedScore'],v40Score=old['combinedScore'],delta=b['combinedScore']-old['combinedScore'],report=str(report/'report.html'),simulationDays=audit['simulationDays'],seconds=summary['seconds'],peakRSSBytes=summary['peakRSSBytes']))
   days+=audit['simulationDays'];stored+=sum(c.get('persistedRows',0) for c in audit['checks']);peak=max(peak,summary.get('peakRSSBytes',0))
   for name,expected in audit['sources'].items():assert sha(Path(name))==expected,name
   for path in [*run.iterdir(),*report.rglob('*')]:protect(path)
   if window=='fixed3y':
    base=Path(summary['decisionBase']);assert summary['p4bPassed'] and audit['decisionBase']['p4bPassed']
    databases.append(audit['decisionBase'])
    for path in base.rglob('*'):protect(path)
 assert len(rows)==10 and len(databases)==5 and days==217652
 protocol=read(target/'protocol.json')
 for name,expected in protocol['frozenEvidence'].items():assert sha(ROOT/name)==expected,name
 original=protocol['migrationSource']
 assert sha(Path(original['path']))==original['sha256'],'Original cold backup changed'
 freeze=read(ROOT/'exports/update-cycle-e1/e1-freeze.json')
 for name,expected in freeze['sources'].items():assert sha(Path(name))==expected,name
 migration=read(target/'migration-verification.json');signed=read(target/'signed-candidate.json')
 assert migration['status']==signed['status']=='passed' and not signed['published']
 assert signed['ruleCommit']==a.rule_commit and signed['dataRules']=='T4/S65'
 assert signed['app']=='3.7.0' and signed['build']=='90' and signed['signatureVerified']
 assert sha(Path(signed['ipa']) if Path(signed['ipa']).is_absolute() else ROOT/signed['ipa'])==signed['ipaSHA256']
 assert sha(ROOT/signed['manifest'])==signed['manifestSHA256']
 for name,expected in migration['outputFiles'].items():
  path=target/'migration-evidence'/name;assert sha(path)==expected,name;protect(path)
 build=read(target/'build-evidence.json');assert build['status']=='passed'
 for name,expected in build['buildInputHashes'].items():assert sha(ROOT/name)==expected,name
 engine=read(target/'engine-identity.json')
 assert engine['status']=='passed' and engine['formalRuleCommit']==a.rule_commit and engine['calculationAndThresholdSourcesUnchanged']
 protected=read(target/'primary-worktree-protection.json');assert sha(Path(protected['sourceRoot'])/'doc/工作交接.md')==protected['handoffSHA256']
 for name in ['protocol.json','build-evidence.json','migration-verification.json','signed-candidate.json','engine-identity.json','protected-evidence-check.json','primary-worktree-protection.json']:protect(target/name)
 with (target/'matrix.csv').open('w',newline='') as f:
  w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
 result=dict(status='passed',createdUTC=datetime.now(timezone.utc).isoformat(),ruleCommit=a.rule_commit,app='3.7.0(90)',dataRules='T4/S65',marketTechnicalVersion=7,strategy='s51-update-cycle-se01-125x125-20261022',baselineVersion=41,decisionBaseVersion=27,decisionBaseFormat=6,reports=rows,decisionBases=databases,validSimulationDays=days,persistedTradeRowsCompared=stored,peakRSSBytes=peak,migration=migration['summary'],protectedPriorFiles=len(freeze['sources']),published=False,pushed=False,originalDataOperated=False,physicalDeviceOperated=False)
 (target/'completion.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));protect(target/'completion.json');protect(target/'matrix.csv')
 (target/'formal-freeze.json').write_text(json.dumps(dict(status='passed',ruleCommit=a.rule_commit,sources=sources),ensure_ascii=False,indent=2))
 print(json.dumps({k:v for k,v in result.items() if k not in ['reports','decisionBases']},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
