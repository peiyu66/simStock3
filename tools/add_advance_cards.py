#!/usr/bin/env python3
"""Six explicit mechanism hypotheses; no Cartesian or fitted thresholds."""
import json,collections as C,sys,time,resource
from pathlib import Path
from add_advance_analysis import O,summarize,save
SPECS=[
 {'id':'AA-F01','mode':'plus1','mechanism':'雙均線下開始改善，增加一票辨識回穩','terms':[['ma20','lt',0],['ma60','lt',0],['d20','gt',0]]},
 {'id':'AA-F02','mode':'plus1','mechanism':'個股冷J但市場動能正，增加一票支援承低','terms':[['j','lt',-1],['mo','gt',0]]},
 {'id':'AA-F03','mode':'plus1','mechanism':'多項九日低點與價格探底重合，增加一票強化低檔證據','terms':[['vote:A-P02','gt',0],['phase','in',[6,7]]]},
 {'id':'AA-F04','mode':'lAlternative','mechanism':'已有A票且多項創低／均線下，允許A-T02不等待當日L訊號','terms':[['vote:A-P02','gt',0],['ma20','lt',0]]},
 {'id':'AA-F05','mode':'lAlternative','mechanism':'已有A票且價格探底／負OSC，允許A-T02不等待當日L訊號','terms':[['phase','in',[6,7]],['osc','lt',0]]},
 {'id':'AA-F06','mode':'restoreAN01','mechanism':'有效正Grade且多項創低伴隨高於常態量，解除A-N01既有一票保守扣分','terms':[['grade','ge',1],['vote:A-P02','gt',0],['vz','gt',0]]},
]
def condition(s,r):
 for field,op,t in s['terms']:
  v=r['votes'].get(field[5:],0) if field.startswith('vote:') else r['features'].get(field)
  if v is None:return False
  if not (v<t if op=='lt' else v>t if op=='gt' else v>=t if op=='ge' else v in t):return False
 return True
def trigger(s,r):
 if not r['eligible'] or not condition(s,r):return False
 f=r['features'];score=f['score']
 if s['mode']=='lAlternative':return -10<f['roi']<1 and f['age']<60 and score>=r['lowthreshold']
 bonus=1 if s['mode']=='plus1' else -r['votes'].get('A-N01',0)
 return (r['roiqual'] and score+bonus>=3) or (r['lowqual'] and score+bonus>=r['lowthreshold'])
def evaluate(spec,units):
 hits=[];allhits=[];first=[];uncovered=[]
 for u in units:
  rs={r['date']:r for r in u['rows']};links=C.defaultdict(list)
  for e in u['events']:
   eligible=[rs[x['date']] for x in e['prior'] if x['round']==e['round'] and x['eligible']]
   triggered=[r for r in eligible if trigger(spec,r)]
   for r in triggered:links[r['date']].append(e)
   if triggered:
    r=triggered[0];hits.append({'sample':u['sample'],'window':u['window'],'stock':u['stock'],'event':e['date'],'date':r['date'],'round':e['round'],'changePct':100*(r['price']/e['price']-1)})
   elif any(r['price']<e['price'] for r in eligible):uncovered.append({'sample':u['sample'],'window':u['window'],'stock':u['stock'],'event':e['date']})
  hh=[]
  for r in u['rows']:
   if trigger(spec,r):
    ees=links[r['date']];row={'sample':u['sample'],'window':u['window'],'stock':u['stock'],'date':r['date'],'round':r['round'],'inEventWindow':bool(ees),'changePct':100*(r['price']/min(ees,key=lambda x:x['date'])['price']-1) if ees else None,'features':r['features'],'votes':r['votes']};hh.append(row);allhits.append(row)
  if hh:first.append(hh[0])
 return {'spec':spec,'eventSummary':summarize(hits),'eventHits':hits,'uncoveredLowerEvents':uncovered,'allDays':len(allhits),'allRounds':len({(x['sample'],x['window'],x['stock'],x['round']) for x in allhits}),'outsideEventWindow':sum(not x['inEventWindow'] for x in allhits),'firstDivergence':{'windows':len(first),'inWindow':summarize([x for x in first if x['inEventWindow']]),'outside':sum(not x['inEventWindow'] for x in first)},'firstRows':first,'allRows':allhits}
def main():
 mode=sys.argv[1];out=O/('hypothesis-discovery.json' if mode=='discovery' else 'hypothesis-validation.json');assert not out.exists()
 if mode=='discovery':
  assert not (O/'hypothesis-specs.json').exists();save('hypothesis-specs.json',SPECS)
 else:assert json.loads((O/'hypothesis-specs.json').read_text())==SPECS
 start=time.monotonic();results={s['id']:[] for s in SPECS}
 # Process 30 windows per sample to bound memory.
 for sample in ('CD' if mode=='discovery' else 'ABCDE'):
  us=[json.loads(p.read_text()) for p in sorted((O/'units').glob(sample+'-*.json')) if mode!='discovery' or p.name[2] in '12']
  for s in SPECS:results[s['id']].append(evaluate(s,us))
 out.write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
 for s in SPECS:
  rr=results[s['id']];hits=[x for r in rr for x in r['eventHits']];first=[x for r in rr for x in r['firstRows']]
  print(s['id'],json.dumps({'events':summarize(hits),'allDays':sum(r['allDays'] for r in rr),'outside':sum(r['outsideEventWindow'] for r in rr),'first':summarize([x for x in first if x['inEventWindow']]),'firstOutside':sum(not x['inEventWindow'] for x in first)},ensure_ascii=False))
 save('hypothesis-'+mode+'-resources.json',{'wallSeconds':time.monotonic()-start,'peakRSSBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
if __name__=='__main__':main()
