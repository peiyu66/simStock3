#!/usr/bin/env python3
"""AA-P02 bounded natural-cut mechanism comparisons; labels never predicates."""
import collections as C,json,math,resource,time,statistics as S
from pathlib import Path
R=Path(__file__).resolve().parents[1];O=R/'exports/add-advance-20261003'
ATOMS=[]
def atom(name,group,field,op,value):ATOMS.append(dict(id=name,group=group,field=field,op=op,value=value))
for field,group in [('ma20','movingAverage'),('ma60','movingAverage'),('d20','movingAverage'),('osc','momentum'),('do','momentum'),('dk','momentum'),('vz','volume'),('v60','volume'),('m20','market'),('m60','market'),('mo','market'),('dm20','market'),('dmo','market')]:atom(field+'Positive',group,field,'gt',0)
for field,val in [('k',9),('j',-1),('ma20',-8),('ma60',-8)]:atom(field+'Below'+str(val),'momentum' if field in ('k','j') else 'movingAverage',field,'lt',val)
for field,group in [('phase','pricePhase'),('mphase','market')]:
 for name,vals in [('range',[1]),('peak',[2,3]),('pullback',[4,5]),('bottom',[6,7]),('rebound',[8,9])]:atom(field+name,group,field,'in',vals)
for name,op,val in [('positive','ge',1),('weak','le',-1),('low','le',-2),('wow','eq',3)]:atom('grade'+name,'grade','grade',op,val)
for name,field,op,val in [('deepLoss','roi','lt',-25),('smallLoss','roi','gt',-10),('early60','age','lt',60),('short180','age','lt',180),('long360','age','gt',360),('firstAdd','invests','eq',1),('recentBuy38','sinceBuy','lt',38),('score2','score','ge',2),('score3','score','ge',3)]:atom(name,'holding',field,op,val)
assert len(ATOMS)<=48
def match(a,r):
 v=r['features'].get(a['field'])
 if v is None or not math.isfinite(v):return None
 op=a['op'];t=a['value']
 return v>t if op=='gt' else v<t if op=='lt' else v>=t if op=='ge' else v<=t if op=='le' else v==t if op=='eq' else v in t
def save(n,x):
 p=O/n;p.parent.mkdir(exist_ok=True,parents=True);p.write_text(json.dumps(x,ensure_ascii=False,allow_nan=False,indent=2)+'\n')
def distribution(xs):
 return {'n':len(xs),'min':min(xs) if xs else None,'median':S.median(xs) if xs else None,'max':max(xs) if xs else None,'ltMinus5':sum(x< -5 for x in xs),'minus5ToMinus1':sum(-5<=x< -1 for x in xs),'minus1To0':sum(-1<=x<0 for x in xs),'equal':sum(x==0 for x in xs),'plus0To1':sum(0<x<=1 for x in xs),'plus1To5':sum(1<x<=5 for x in xs),'gtPlus5':sum(x>5 for x in xs)}
def summarize(hits):
 ds=[h['changePct'] for h in hits];low=[h for h in hits if h['changePct']<0];high=[h for h in hits if h['changePct']>0];lc=C.Counter(h['stock'] for h in low)
 return {'lower':len(low),'higher':len(high),'equal':len(hits)-len(low)-len(high),'stocks':len({h['stock'] for h in hits}),'lowStocks':len(lc),'lowWindows':sorted({h['window'] for h in low}),'lowWithoutLargestStock':len(low)-max(lc.values(),default=0),'distribution':distribution(ds),'lowDistribution':distribution([h['changePct'] for h in low]),'highDistribution':distribution([h['changePct'] for h in high])}
def main():
 start=time.monotonic();cpu=time.process_time();assert not (O/'mechanisms.json').exists()
 save('atom-specs.json',ATOMS)
 units=[json.loads(p.read_text()) for p in sorted((O/'units').glob('[CD]-[12]-*.json'))];assert len(units)==40
 events=[];allrows=[];categories=C.Counter();examples=[];bytype=C.defaultdict(list)
 for u in units:
  rs={r['date']:r for r in u['rows']};allrows.extend((u,r) for r in u['rows'] if r['eligible'])
  for e in u['events']:
   valid=[rs[x['date']] for x in e['prior'] if x['round']==e['round'] and x['eligible']]
   events.append((u,e,valid))
   for r in valid:
    f=r['features'];low=r['price']<e['price']
    route='scoreOnly' if r['roiqual'] or r['lowqual'] else 'earlyNonLWithScore' if -10<f['roi']<1 and f['age']<60 and f['score']>=r['lowthreshold'] else 'earlyNonLAndScore' if -10<f['roi']<1 and f['age']<60 else 'otherQualification'
    categories[route+('Low' if low else 'Other')]+=1
    row={'sample':u['sample'],'window':u['window'],'stock':u['stock'],'name':u['name'],'event':e['date'],'date':r['date'],'round':e['round'],'changePct':100*(r['price']/e['price']-1),'route':route,'features':f,'votes':r['votes'],'rule':r['rule'],'entryRule':r['entryRule']}
    bytype[route].append(row)
    if low:examples.append(row)
 out=[]
 for a in ATOMS:
  sides={True:[],False:[]};unknown=0;eligiblehits=[]
  for u,e,rs in events:
   for side in (True,False):
    r=next((r for r in rs if match(a,r) is side),None)
    if r:sides[side].append({'sample':u['sample'],'window':u['window'],'stock':u['stock'],'event':e['date'],'date':r['date'],'changePct':100*(r['price']/e['price']-1)})
  for u,r in allrows:
   m=match(a,r)
   if m is None:unknown+=1
   if m:eligiblehits.append((u,r))
  out.append({'atom':a,'true':summarize(sides[True]),'false':summarize(sides[False]),'trueEvents':sides[True],'falseEvents':sides[False],'allEligibleDaysTrue':len(eligiblehits),'allEligibleRoundsTrue':len({(u['sample'],u['window'],u['stock'],r['round']) for u,r in eligiblehits}),'unknownDays':unknown})
 save('mechanisms.json',out);save('discovery-cases.json',{'events':len(events),'eligibleDays':len(allrows),'lowerCases':examples,'qualificationRoutes':dict(categories),'routeDistributions':{k:summarize(v) for k,v in bytype.items()}})
 resource_stats={'wallSeconds':time.monotonic()-start,'cpuSeconds':time.process_time()-cpu,'peakRSSBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'atoms':len(ATOMS)};assert resource_stats['peakRSSBytes']<512*1024**2;save('mechanism-resources.json',resource_stats)
 print(json.dumps({'resources':resource_stats,'routes':dict(categories)},indent=2))
 for x in out:print(x['atom']['id'],x['true']['lower'],x['true']['higher'],x['false']['lower'],x['false']['higher'],x['allEligibleDaysTrue'])
if __name__=='__main__':main()
