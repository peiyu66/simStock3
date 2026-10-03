#!/usr/bin/env python3
"""EA P02 completion: six bounded mechanisms, no strategy replay/search grid."""
import datetime as D,collections as C,csv,hashlib,json,math,resource,sqlite3,statistics as S,time,sys
from pathlib import Path
R=Path(__file__).resolve().parents[1];B=R/'exports/entry-advance-20261003';O=B/'mechanism-completion-v2';T=time.monotonic();CPU=time.process_time();HASH={}
resource.setrlimit(resource.RLIMIT_CPU,(900,900))
PHASE={0:'unavailable',1:'sideways',2:'peakEarly',3:'peakLate',4:'pullbackEarly',5:'pullbackLate',6:'bottomEarly',7:'bottomLate',8:'reboundEarly',9:'reboundLate'}
GRADE={-3:'damn',-2:'low',-1:'weak',0:'none',1:'fine',2:'high',3:'wow'}
# Natural signs and formal categories only. No optimized thresholds or cartesian products.
PRED={
'M1-shortAbove':lambda f:f['ma20']>0,'M1-mediumAbove':lambda f:f['ma60']>0,'M1-shortImproving':lambda f:f['d20']>0,'M1-maSlopePositive':lambda f:f['ma20Days']>0,
'M2-oscPositive':lambda f:f['osc']>0,'M2-oscImproving':lambda f:f['do']>0,'M2-kImproving':lambda f:f['dk']>0,'M2-kCold':lambda f:f['k']<9,'M2-jCold':lambda f:f['j']<-1,
'M3-volumeBelowNormal':lambda f:f['vz']<0,
'M4-stockPeak':lambda f:f['phase'] in (2,3),'M4-stockPullback':lambda f:f['phase'] in (4,5),'M4-stockBottom':lambda f:f['phase'] in (6,7),'M4-stockRebound':lambda f:f['phase'] in (8,9),'M4-stockSideways':lambda f:f['phase']==1,
'M5-marketShortAbove':lambda f:f['m20']>0,'M5-marketMediumAbove':lambda f:f['m60']>0,'M5-marketOscPositive':lambda f:f['mo']>0,'M5-marketShortImproving':lambda f:f['dm20']>0,'M5-marketOscImproving':lambda f:f['dmo']>0,
'M6-validPositiveGrade':lambda f:f['grade']>=1,'M6-validNegativeGrade':lambda f:f['grade']<=-1,
}
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def read(p):HASH[str(p.relative_to(R))]=sha(p);return json.loads(p.read_text())
def save(n,x):
 p=O/n;p.parent.mkdir(parents=True,exist_ok=True);q=p.with_suffix('.tmp');q.write_text(json.dumps(x,ensure_ascii=False,allow_nan=False,separators=(',',':'))+'\n');q.replace(p)
def usage():
 past=sum(json.loads(p.read_text())['cpuSeconds'] for p in O.glob('*-resources.json'))
 u={'cpuSeconds':time.process_time()-CPU,'wallSeconds':time.monotonic()-T,'peakRSSBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'allocatedBytes':sum(p.stat().st_blocks*512 for p in B.rglob('*') if p.is_file())}
 assert past+u['cpuSeconds']<900 and u['peakRSSBytes']<512*1024**2 and u['allocatedBytes']<128*1024**2,u
 return u
def db(p):
 HASH[str(p.relative_to(R))]=sha(p);w=Path(str(p)+'-wal');assert not w.exists() or w.stat().st_size==0
 c=sqlite3.connect(p.as_uri()+'?mode=ro&immutable=1',uri=True);c.row_factory=sqlite3.Row;assert c.execute('pragma quick_check').fetchone()[0]=='ok';return c

def enrich():
 assert not (O/'enrich-complete.json').exists()
 inv=read(B/'inventory.json');old=read(B/'source-hashes.json')
 for p,h in old.items():assert sha(R/p)==h,p
 uidlist=read(B/'extraction-complete.json')['units'];out=[];checks=C.Counter()
 day=lambda t:int((D.datetime(2001,1,1)+D.timedelta(seconds=t,hours=8)).strftime("%Y%m%d"))
 mp=R/'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af/market-technical.csv';HASH[str(mp.relative_to(R))]=sha(mp)
 with mp.open() as f:markets={int(x['date'].replace('-','')):x for x in csv.DictReader(f)}
 for sample in 'ABCDE':
  bp=R/inv[sample]['decisionBase'];rp=next(R.glob('exports/backtest-reports/baseline-'+sample.lower()+'-v37-*-fixed3y-*'))
  with db(bp/'decisions.sqlite') as c:
   events={};ids={}
   for e in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase in (1,2) and inventory_before=0'):
    e=dict(e);key=(e['window_id'],e['stock_id'],e['trade_date']);events.setdefault(key,{})[e['phase']]=e;ids[e['event_id']]={'votes':{},'gates':[]}
   for eid,rid,v in c.execute('select event_id,rule_id,contribution from event_votes join rules using(rule_key)'):
    if eid in ids:ids[eid]['votes'][rid]=v
   for eid,rid in c.execute('select event_id,rule_id from event_gates join rules using(rule_key)'):
    if eid in ids:ids[eid]['gates'].append(rid)
  for w,fn in enumerate(('browse.store','period-20200722.store','period-20230722.store'),1):
   with db(rp/fn) as c:
    extras={(s,d):[hi,lz,n] for s,d,hi,lz,n in []}
    for s in c.execute('select Z_PK,ZSID from ZSTOCK'):
     rs=c.execute('select ZDATETIME,ZTHIGHDIFF,ZTLOWDIFFZ250 from ZTRADE where ZSTOCK=? order by ZDATETIME',(s['Z_PK'],))
     for n,r in enumerate(rs):extras[s['ZSID'],day(r[0])]=(r[1],r[2],n)
   for uid in [x for x in uidlist if x.startswith(f'{sample}-{w}-')]:
    u=read(B/'units'/f'{uid}.json');identity={'unit':HASH[str((B/'units'/f'{uid}.json').relative_to(R))],'decisionBase':HASH[str((bp/'decisions.sqlite').relative_to(R))]}
    for r in u['rows']:
     f=r['features'];d=r['date'];ee=events[w,u['stock'],d];h=ee[1];l=ee.get(2)
     r['votes']={'H':ids[h['event_id']]['votes'],'L':ids[l['event_id']]['votes'] if l else None};r['gates']={'H':ids[h['event_id']]['gates'],'L':ids[l['event_id']]['gates'] if l else None}
     assert math.isclose(sum(r['votes']['H'].values())-h['decision_threshold'],f['hMargin'])
     if l:assert math.isclose(sum(r['votes']['L'].values())-5,f['lMargin'])
     r['hPlanned']=h['planned_action']=='H';r['lPlanned']=bool(l and l['planned_action']=='L')
     hi,lz,n=extras[u['stock'],d];m=markets.get(d);mature=bool(m and n>=249 and int(m['price_observation_count'])>=250)
     e1=bool(mature and f['mphase']==7 and f['mjz']>-.88 and (f['grade']>=1 or f['ma60']>-3.6))
     e2=bool(mature and f['dz']<-.85 and -10<float(m['market_high_diff_250'])<-1.7 and (hi>2.2 or lz<-.92))
     r['hDelayTech']={'E01':e1,'E02':e2};r['inputsMature']=mature;r['key']=uid+':'+str(d)
     if r['feasible'] and f['hMargin']>=0:assert r['e1']==e1 and r['e2']==(not e1 and e2)
     checks['flatGateVoteRows']+=1
    save('units/'+uid+'.json',u);out.append(uid);save('progress.json',{'stage':'enrich','unit':uid,'done':len(out),'resources':usage()});print(uid,flush=True)
 save('sources.json',HASH);save('enrich-complete.json',{'units':out,'checks':dict(checks)});save('enrich-resources.json',usage())
def units():
 for uid in json.loads((O/'enrich-complete.json').read_text())['units']:yield json.loads((O/'units'/f'{uid}.json').read_text())
def discovery(u):return u['sample'] in 'ABCD' and u['window']<3
def eligible(r):return r['feasible'] and not r['quality'] and not r['normal']
def label(v):return 'lower' if v>0 else 'higher' if v<0 else 'equal'
def links(u):
 rr={r['date']:r for r in u['rows']}
 for e in u['events']:
  for a in e['prior']:
   r=rr.get(a['date'])
   if r and eligible(r):yield e,r,100*(e['price']-r['price'])/e['price']
def brief(items):
 # Event based first qualifying day, with unique dates/segments as separate units.
 events={};days=set();segs=set();stock=C.Counter();by=C.defaultdict(C.Counter);vals=[]
 for u,e,r,v in items:
  uid=f'{u["sample"]}-{u["window"]}-{u["stock"]}';key=uid+':'+str(e['date']);events.setdefault(key,(u,e,r,v));days.add(r['key']);segs.add((uid,r['segment']))
 for u,e,r,v in events.values():
  k=label(v);stock[u['stock']]+=v>0;by[u['sample']+str(u['window'])][k]+=1;vals.append(v)
 worst=sorted(events.items(),key=lambda kv:kv[1][3])[:3];best=sorted(events.items(),key=lambda kv:-kv[1][3])[:3]
 return {'events':len(events),'labels':dict(C.Counter(label(v) for v in vals)),'uniqueDays':len(days),'segments':len(segs),'stocks':len({u['stock'] for u,e,r,v in events.values()}),'byWindow':{k:dict(v) for k,v in by.items()},'lowerAfterDroppingLargestStock':sum(stock.values())-(max(stock.values()) if stock else 0),'examples':{'lower':[{'event':k,'day':r['date'],'savingPct':v,'grade':r['features']['grade'],'phase':r['features']['phase'],'hMargin':r['features']['hMargin'],'lMargin':r['features']['lMargin'],'votes':r['votes']} for k,(u,e,r,v) in best if v>0],'higher':[{'event':k,'day':r['date'],'savingPct':v,'grade':r['features']['grade'],'phase':r['features']['phase'],'hMargin':r['features']['hMargin'],'lMargin':r['features']['lMargin'],'votes':r['votes']} for k,(u,e,r,v) in worst if v<0]}}
def diagnostic():
 assert not (O/'mechanism-diagnostics.json').exists()
 ls=[];rr=[];foriginal=[]
 for u in units():
  if discovery(u):ls.extend((u,e,r,v) for e,r,v in links(u));rr.extend((u,r) for r in u['rows'] if eligible(r))
 save('mechanism-protocol.json',{'mechanisms':['M1 stock MA','M2 stock OSC/KD','M3 volume','M4 categorical price path','M5 market regime','M6 decision Grade/votes/gates'],'predicates':list(PRED),'thresholds':'natural zero, formal K<9/J<-1 and phase/Grade categories only','noGrid':True,'discovery':'A-D W1/W2; all other samples already seen in first pass, not blind','candidateLimit':4,'priorCandidateCount':2,'newCombinationSlots':2})
 summaries={}
 for name,p in PRED.items():
  yes=[a for a in ls if p(a[2]['features'])];no=[a for a in ls if not p(a[2]['features'])]
  summaries[name]={'true':brief(yes),'false':brief(no),'eligibleDaysTrue':sum(p(r['features']) for u,r in rr)}
 categories={}
 for key in ('phase','mphase','grade','hMargin','lMargin'):
  categories[key]={str(value):brief([a for a in ls if a[2]['features'][key]==value]) for value in sorted({r['features'][key] for u,r in rr if r['features'][key] is not None})}
 # Positive/negative profiles count unique event/category pairs, not average enum codes.
 gates={};voteprofiles={};action={}
 for name,test in {'HscoreFailed':lambda r:r['features']['hMargin']<0,'HdelayE01':lambda r:r['e1'],'HdelayE02':lambda r:r['e2'],'Hplus1Reach':lambda r:r['features']['hMargin']==-1 and not any(r['hDelayTech'].values()),'Lplus1Reach':lambda r:r['features']['lMargin']==-1,'BothPlus1Miss':lambda r:not(r['features']['hMargin']==-1 and not any(r['hDelayTech'].values())) and r['features']['lMargin']!=-1}.items():
  items=[a for a in ls if test(a[2])];gates[name]=brief(items);gates[name]['uniqueEligibleDays']=sum(test(r) for u,r in rr)
 for branch in ('H','L'):
  rules=sorted({k for u,r in rr for k in (r['votes'][branch] or {})})
  voteprofiles[branch]={rule:brief([a for a in ls if rule in (a[2]['votes'][branch] or {})]) for rule in rules}
 save('mechanism-diagnostics.json',{'population':brief(ls),'predicates':summaries,'categories':categories,'gates':gates,'votes':voteprofiles})
 save('diagnostic-resources.json',usage())
 for k,v in summaries.items():print(k,'true',v['true']['labels'],'false',v['false']['labels'],'days',v['eligibleDaysTrue'])
 print('gates',{k:(v['labels'],v['uniqueEligibleDays']) for k,v in gates.items()})

def freeze():
 assert not (O/'frozen-cards.json').exists()
 save('frozen-cards.json',{'timestamp':time.time(),'basis':sha(O/'mechanism-diagnostics.json'),'cards':[
 {'id':'EA-H01','branch':'H','action':'flat H +1 before H-T01','terms':'ma20>0 and m20>0','origin':'unchanged initial hypothesis'},
 {'id':'EA-L01','branch':'L','action':'flat L +1 before L-T01 after full H failure','terms':'ma20<0 and dm20>0','origin':'unchanged initial hypothesis'},
 {'id':'EA-H02','branch':'H','action':'cancel credited H-N10 only, flat only before H-T01','terms':'H-N10<0 and ma20>0 and mo>0 and do>0','origin':'test low-volume penalty exception during stock OSC recovery with price above MA20 and positive market OSC; no other penalty removed'},
 {'id':'EA-L02','branch':'L','action':'extend L-P12 +1 to early rebound only, flat only after full H failure','terms':'phase==8 and ma20<0 and m20>0','origin':'advance existing late-rebound low-buy confirmation one categorical stage while stock below MA20 and market above MA20; never double late-rebound vote'}],
 'limits':'four cards total; no further variants or threshold search; preserve original H delays, L5, priority, execution; no holding-state effects'})
def formula(cid,r):
 f=r['features']
 if cid=='EA-H01':return f['ma20']>0 and f['m20']>0
 if cid=='EA-L01':return f['ma20']<0 and f['dm20']>0
 if cid=='EA-H02':return (r['votes']['H'].get('H-N10',0)<0 and f['ma20']>0 and f['mo']>0 and f['do']>0)
 if cid=='EA-L02':return f['phase']==8 and f['ma20']<0 and f['m20']>0
 raise ValueError(cid)
def actionable(card,r):
 if not r['feasible'] or r['quality'] or not formula(card['id'],r):return False
 f=r['features']
 if card['branch']=='H':
  bonus=-r['votes']['H'].get('H-N10',0) if card['id']=='EA-H02' else 1
  return f['hMargin']<0<=f['hMargin']+bonus and not any(r['hDelayTech'].values())
 return not r['normal'] and f['lMargin'] is not None and f['lMargin']<0<=f['lMargin']+1

def cards():
 assert not (O/'cards-complete.json').exists()
 frozen=read(O/'frozen-cards.json');results={};sets={};lowercoverage={};opportunity=set();gatecoverage=C.defaultdict(set);mechanisms=C.defaultdict(set)
 for u in units():
  if not discovery(u):continue
  for e,r,v in links(u):
   if v<=0:continue
   key=(u['sample'],u['window'],u['stock'],e['date']);opportunity.add(key)
   if r['features']['hMargin']==-1 and not any(r['hDelayTech'].values()):gatecoverage['H+1'].add(key)
   if r['features']['lMargin']==-1:gatecoverage['L+1'].add(key)
   for name,pred in PRED.items():
    if pred(r['features']):mechanisms[name].add(key)
 for card in frozen['cards']:
  cid=card['id'];allhits=[];first=[];comparisons=[];counts=C.defaultdict(C.Counter);labels=C.defaultdict(C.Counter);uniques=C.defaultdict(set);cases=[];formulaItems=[]
  for u in units():
   uid=f'{u["sample"]}-{u["window"]}-{u["stock"]}';phase='discovery' if discovery(u) else 'knownReview';hits=[];em=C.defaultdict(list)
   for e,r,v in links(u):em[r['date']].append((e,v))
   if discovery(u):formulaItems.extend((u,e,r,v) for e,r,v in links(u) if formula(cid,r))
   for r in u['rows']:
    if formula(cid,r):counts[phase]['rawFormulaDays']+=1
    if not actionable(card,r):continue
    linked=em[r['date']];rec={'key':r['key'],'unit':uid,'phase':phase,'date':r['date'],'stock':u['stock'],'segment':r['segment'],'kind':'reclassifyLtoH' if r['normal'] else 'newEntry','features':r['features'],'votes':r['votes'],'linked':[{'event':e['date'],'originalRule':e['rule'],'savingPct':v,'sameSegment':e['segment']==r['segment'],'truncated':e['leftTruncated'],'gap':bool(e['missingMarketSessions'])} for e,v in linked]}
    hits.append(rec);allhits.append(rec);counts[phase]['hitDays']+=1;counts[phase]['outsideDays']+=not linked;counts[phase]['reclassifications']+=r['normal'];uniques[phase].add((uid,r['segment']))
   if hits:first.append(hits[0])
   bydate={r['date']:r for r in hits}
   for e in u['events']:
    matches=[bydate[x['date']] for x in e['prior'] if x['date'] in bydate and bydate[x['date']]['kind']=='newEntry']
    if not matches:continue
    r=matches[0];v=next(x['savingPct'] for x in r['linked'] if x['event']==e['date']);rec={'unit':uid,'stock':u['stock'],'phase':phase,'event':e['date'],'date':r['date'],'originalRule':e['rule'],'savingPct':v,'sameSegment':r['segment']==e['segment'],'gap':bool(e['missingMarketSessions']),'truncated':e['leftTruncated']}
    comparisons.append(rec);labels[phase][label(v)]+=1
  for phase in counts:counts[phase]['segments']=len(uniques[phase])
  summaries={}
  for phase in ('discovery','knownReview'):
   es=[x for x in comparisons if x['phase']==phase];fs=[x for x in first if x['phase']==phase];fc=C.Counter();risk=C.Counter();pos=C.Counter()
   for x in fs:
    labs={label(a['savingPct']) for a in x['linked']}
    fc['outside' if not labs else 'mixed' if len(labs)>1 else next(iter(labs))]+=1
   for x in es:
    if x['savingPct']<0:risk['<=1%' if x['savingPct']>=-1 else '1-5%' if x['savingPct']>=-5 else '>5%']+=1
    if x['savingPct']>0:pos[x['stock']]+=1
   summaries[phase]={'events':dict(labels[phase]),'firstDivergence':dict(fc),'higherMagnitude':dict(risk),'crossSegment':sum(not x['sameSegment'] for x in es),'stocks':len({x['stock'] for x in es}),'lowerAfterDroppingLargestStock':sum(pos.values())-max(pos.values(),default=0),'byStockLower':dict(pos),'examplesLower':sorted([x for x in es if x['savingPct']>0],key=lambda x:-x['savingPct'])[:3],'examplesHigher':sorted([x for x in es if x['savingPct']<0],key=lambda x:x['savingPct'])[:3]}
  result={'card':card,'counts':{k:dict(v) for k,v in counts.items()},'summary':summaries,'formulaBeforeGate':brief(formulaItems),'shadowDays':allhits,'firstDivergences':first,'eventComparisons':comparisons,'limitations':'Only first stock/window divergence has valid baseline S; later records are exposures, never candidate performance.'}
  save('card-'+cid+'.json',result);results[cid]={k:result[k] for k in ('card','counts','summary','formulaBeforeGate')};sets[cid]={x['key'] for x in allhits};lowercoverage[cid]={(x['unit'],a['event']) for x in allhits if x['phase']=='discovery' for a in x['linked'] if a['savingPct']>0}
  # Original first two cards must reproduce exact changed-date sets, including reclassification.
  if cid in ('EA-H01','EA-L01'):
   old=read(B/('card-'+cid+'.json'));assert sets[cid]=={x['unit']+':'+str(x['date']) for x in old['shadowDays']},cid
  print(cid,json.dumps({'counts':result['counts'],'summary':summaries},ensure_ascii=False),flush=True);usage()
 save('candidate-overlap.json',{'datePairs':{a+'/'+b:len(sets[a]&sets[b]) for a in sets for b in sets if a<b},'newDatesVsInitial':{a:len(sets[a]-(sets['EA-H01']|sets['EA-L01'])) for a in sets},'lowerEventCoverage':{a:len(s) for a,s in lowercoverage.items()},'newLowerEventsVsInitial':{a:len(s-(lowercoverage['EA-H01']|lowercoverage['EA-L01'])) for a,s in lowercoverage.items()}})
 union=gatecoverage['H+1']|gatecoverage['L+1'];save('coverage.json',{'discoveryAnyLowerOpportunityEvents':len(opportunity),'Hplus1AnyLowerEvents':len(gatecoverage['H+1']),'Lplus1AnyLowerEvents':len(gatecoverage['L+1']),'union':len(union),'unreachableByEitherPlus1':len(opportunity-union),'singleMechanismAnyLowerCoverage':{k:len(v) for k,v in mechanisms.items()},'nonAdditive':True})
 save('cards-complete.json',results);save('cards-resources.json',usage())

def audit():
 checks=C.Counter();sources=json.loads((O/'sources.json').read_text())
 for p,h in sources.items():assert sha(R/p)==h,p
 cards=json.loads((O/'frozen-cards.json').read_text())['cards'];index={f'{u["sample"]}-{u["window"]}-{u["stock"]}':u for u in units()}
 for uid,u in index.items():
  old=json.loads((B/'units'/f'{uid}.json').read_text());assert u['events']==old['events']
  for a,b in zip(u['rows'],old['rows']):
   for k,v in b.items():assert a[k]==v,(uid,k)
   checks['unchangedOriginalFlatRows']+=1
 for card in cards:
  out=json.loads((O/('card-'+card['id']+'.json')).read_text());first={};seen=set()
  for hit in out['shadowDays']:
   u=index[hit['unit']];r=next(r for r in u['rows'] if r['date']==hit['date']);assert r['feasible'] and not r['quality'];assert hit['key'] not in seen;seen.add(hit['key']);first.setdefault(hit['unit'],hit)
   # Independently check effective threshold and original gate failure, then exact event arithmetic.
   if card['branch']=='H':
    bonus=-r['votes']['H'].get('H-N10',0) if card['id']=='EA-H02' else 1
    assert r['features']['hMargin']<0 and r['features']['hMargin']+bonus>=0 and not any(r['hDelayTech'].values())
   else:assert not r['normal'] and r['features']['lMargin']==-1
   for relation in hit['linked']:
    e=next(e for e in u['events'] if e['date']==relation['event']);assert hit['date'] in {p['date'] for p in e['prior']};assert math.isclose(relation['savingPct'],100*(e['price']-r['price'])/e['price'],abs_tol=1e-8);checks['eventRelations']+=1
   checks['shadowRows']+=1
  assert list(first.values())==out['firstDivergences'];checks['firstDivergences']+=len(first)
 # Quantify mechanism overlap without inventing composites: observed lower event sets.
 ms=C.defaultdict(set);gateCase=C.defaultdict(list)
 for u in index.values():
  if not discovery(u):continue
  for e,r,v in links(u):
   if v>0:
    key=(u['sample'],u['window'],u['stock'],e['date'])
    for name,p in PRED.items():
     if p(r['features']):ms[name.split('-')[0]].add(key)
   f=r['features'];bucket='outsidePlus1' if f['hMargin']!=-1 and f['lMargin']!=-1 else 'reachablePlus1'
   gateCase[bucket].append((u,e,r,v))
 save('mechanism-overlap.json',{'groupAnyLowerEvents':{k:len(v) for k,v in ms.items()},'pairIntersection':{a+'/'+b:len(ms[a]&ms[b]) for a in ms for b in ms if a<b},'warning':'M6 includes both positive and negative Grade, hence is not a buy signal; groups are descriptive unions only.'})
 save('gate-case-examples.json',{k:brief(v) for k,v in gateCase.items()})
 save('audit.json',{'checks':dict(checks),'sourcesUnchanged':len(sources),'toolHash':sha(Path(__file__)),'resultHashes':{p.name:sha(p) for p in O.glob('*.json') if p.name!='audit.json'},'originalEvidencePreserved':True,'noReplay':True});save('audit-resources.json',usage());print(dict(checks))
if __name__=='__main__':{'enrich':enrich,'diagnostic':diagnostic,'freeze':freeze,'cards':cards,'audit':audit}[sys.argv[1]]()
