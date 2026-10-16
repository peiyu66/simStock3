"""Verify S64 historical parity with frozen S63, including warning payloads and source provenance."""
import contextlib,hashlib,json,os,sqlite3,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
REFERENCE=Path(os.environ.get('SIMSTOCK_BASELINE_REFERENCE_ROOT',str(ROOT)))
COMMIT=(ROOT/'exports/baseline-v40-rule-commit.txt').read_text().strip()
assert subprocess.check_output(['git','rev-parse',COMMIT+'^{commit}'],cwd=ROOT,text=True).strip()==COMMIT
RULE='s50-lc02-removed-20261007'
def read(p): return json.loads(p.read_text())
def connect(p):
 db=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True); db.row_factory=sqlite3.Row; return db
def rid(c,w,v):
 name,day=('resumable-update-t3s64','20261016') if v==40 else ('warning-p-t3s63','20261008')
 return f'baseline-{c.lower()}-v{v}-s50-{name}-9y-{w}-600w-{day}'
def normalize_warning(raw):
 if raw is None:return None
 obj=json.loads(raw);obj.pop('dataRules',None);return obj

def audit(c):
 checks=[];count=0
 for w in ['fixed3y','fullstress']:
  d=ROOT/'exports/backtest-reports'/rid(c,w,40); old=REFERENCE/'exports/backtest-reports'/rid(c,w,39)
  m,b,o=read(d/'manifest.json'),read(d/'baseline.json'),read(old/'baseline.json')
  assert (d/'.complete').read_text().strip()==m['runID']==rid(c,w,40)
  for x in [m,b]:
   assert x['ruleCommit']==COMMIT and x['dataRuleVersion']=='T3/S64' and x['ruleVersion']==RULE
   for k in ['sampleID','historyStart','through','moneyBaseWan','automaticInvestments','periodStarts','marketInput']:assert x[k]==o[k],(c,w,k)
  assert b['combinedScore']==o['combinedScore'] and b['stocks']==o['stocks'] and b['groups']==o['groups'],(c,w,'scores')
  assert (d/'periods.csv').read_bytes()==(old/'periods.csv').read_bytes(),(c,w,'periods')
  html=(d/'report.html').read_text();assert all(x in html for x in [COMMIT,'T3/S64',rid(c,w,39)])
  for name in m['reportFiles']:assert (d/name).is_file()
  stores=['browse.store']+(['period-20200722.store','period-20230722.store'] if w=='fixed3y' else [])
  for name in stores:
   with contextlib.closing(connect(d/name)) as db, contextlib.closing(connect(old/name)) as prior:
    assert db.execute('pragma integrity_check').fetchone()[0]=='ok'
    assert [tuple(x) for x in db.execute('SELECT DISTINCT ZTECHNICALSTATEVERSION,ZSIMULATIONSTATEVERSION,ZTECHNICALDIRTYFROM,ZSIMULATIONDIRTYFROM FROM ZSTOCK')]==[(3,64,None,None)]
    cols=[x['name'] for x in prior.execute('pragma table_info(ZTRADE)') if x['name'] not in ['Z_PK','Z_ENT','Z_OPT','ZSTOCK','ZSIMANNUALWARNINGDATA']]
    q='SELECT s.ZSID,'+','.join('t.'+x for x in cols)+',t.ZSIMANNUALWARNINGDATA FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK ORDER BY s.ZSID,t.ZDATETIME'
    n=0
    for x,y in zip(db.execute(q),prior.execute(q),strict=True):
     assert tuple(x)[:-1]==tuple(y)[:-1],(c,w,name,n,'persisted fields')
     assert normalize_warning(x[-1])==normalize_warning(y[-1]),(c,w,name,n,'warning')
     n+=1
    assert db.execute('SELECT COUNT(*) FROM ZTRADE WHERE ZSIMMARKETISPROVISIONAL!=0 OR ZSIMPROVISIONALEFFECTIVEINVESTMENT IS NOT NULL').fetchone()[0]==0
    # No invented current-day source: every recorded historical source must match the stock date.
    assert db.execute("SELECT COUNT(*) FROM ZTRADE WHERE ZSIMMARKETSOURCEDATE IS NOT NULL AND CAST((ZSIMMARKETSOURCEDATE+28800)/86400 AS INT)!=CAST((ZDATETIME+28800)/86400 AS INT)").fetchone()[0]==0
    count+=n;checks.append(dict(window=w,store=name,rows=n,allExistingFieldsEqual=True,warningEqualExceptDataVersion=True))
 bid=f'{c.lower()}-{"abcde9" if c=="E" else "abcd9"}-v3-{RULE}-t3-s64-{COMMIT[:12]}-fixed3y-20260722-v26'
 d=ROOT/'exports/backtest-decision-bases'/bid; bm=read(d/'manifest.json')
 assert bm['decisionBaseID']==bid and bm['ruleCommit']==COMMIT and bm['dataRuleVersion']=='T3/S64'
 assert bm['formatVersion']==6 and bm['stockCount']==10 and bm['windowCount']==3 and bm['outcomeCount']==30
 for f in ['.complete','.p4b-complete']:assert (d/f).read_text().strip()==bid
 with contextlib.closing(connect(d/'decisions.sqlite')) as db:
  assert db.execute('pragma integrity_check').fetchone()[0]=='ok';metadata=dict(db.execute('select key,value from metadata'))
  assert metadata['ruleCommit']==COMMIT and metadata['dataRuleVersion']=='T3/S64'
  assert db.execute('select count(*) from rules').fetchone()[0]==99
  events=db.execute('select count(*) from decision_events').fetchone()[0]
  assert events==bm['eventCount'] and events>0
 return dict(sample=c,passed=True,ruleCommit=COMMIT,rows=count,events=events,stores=checks)
if __name__=='__main__':
 samples=sys.argv[1:] or list('ABCDE');results=[audit(c) for c in samples]
 out=ROOT/('exports/baseline-v40-verification-'+''.join(samples)+'.json');out.write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n');print(json.dumps(results,ensure_ascii=False))
