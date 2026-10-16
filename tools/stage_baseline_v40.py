"""Stage verified frozen inputs into the explicitly isolated v40 runner container."""
import hashlib,json,shutil,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
source=ROOT/'exports/price-update-resume-20261016/frozen-inputs'
target=Path(sys.argv[1])
expected=sys.argv[2]
assert target.name=='InternalBacktest' and expected in target.parts, 'Dedicated run only'
for row in json.loads((source/'sources.json').read_text()):
 p=source/row['relative']; assert hashlib.sha256(p.read_bytes()).hexdigest()==row['sha256']
 d=target/row['relative']; d.parent.mkdir(parents=True,exist_ok=True)
 if d.exists():
  # TechnicalBases are disposable run-local schema-migrated copies; never overwrite a completed one.
  if 'TechnicalBases' in d.parts: continue
  assert hashlib.sha256(d.read_bytes()).hexdigest()==row['sha256']; continue
 shutil.copy2(p,d)
 assert hashlib.sha256(d.read_bytes()).hexdigest()==row['sha256']
print('Frozen inputs staged and verified')
