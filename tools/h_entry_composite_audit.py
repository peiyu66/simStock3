#!/usr/bin/env python3
"""Post-freeze descriptive diagnostics; never tune or overwrite frozen rules."""
import copy
import json
from collections import Counter
import numpy as np
import h_entry_composite as h


def entry_stats(signal, rounds):
    result = {}
    for w in sorted({r['window'] for r in rounds}):
        rs = [r for r in rounds if r['window'] == w]
        pos = [r for r in rs if r['opportunity']]
        neg = [r for r in rs if r['closed'] and not r['bottom_boundary'] and not r['opportunity']]
        result[str(w)] = dict(positive=len(pos), other=len(neg),
            positive_hits=sum(bool(signal[r['entry']]) for r in pos),
            other_hits=sum(bool(signal[r['entry']]) for r in neg),
            enrichment=(sum(signal[r['entry']] for r in pos)/len(pos)-sum(signal[r['entry']] for r in neg)/len(neg)) if pos and neg else None)
    return result


def refit(atom, train):
    atom = copy.deepcopy(atom)
    values = train[:, atom['feature']]
    values = values[np.isfinite(values)]
    origin = atom['origin']
    if origin == 'q25_q75':
        atom['value'] = [h.coarse(float(np.quantile(values, q))) for q in (.25, .75)]
    elif origin.startswith('q'):
        atom['value'] = h.coarse(float(np.quantile(values, int(origin[1:])/100)))
    return atom


def main():
    X, keys, rounds = h.load('discovery')
    atoms = json.loads((h.OUT/'atoms.json').read_text())
    frozen = json.loads((h.OUT/'frozen-candidates.json').read_text())
    for name, digest in frozen['discoveryInputs'].items():
        assert h.sha(h.OUT/name) == digest, name
    stocks = sorted({k['stock'] for k in keys})
    stock_ids = np.array([k['stock'] for k in keys])
    candidates = frozen['candidates']
    results = []
    evaluations = 0
    entry_indices = [r['entry'] for r in rounds]
    for c in candidates:
        aids = sorted({a for b in c['expr'] for a in b})
        original, valid = h.eval_expr(c['expr'], atoms, X)
        oof = np.zeros(len(X), dtype=bool)
        folds = []
        for stock in stocks:
            train = X[stock_ids != stock]
            revised = list(atoms)
            for aid in aids:
                revised[aid] = refit(atoms[aid], train)
            ix = stock_ids == stock
            oof[ix], _ = h.eval_expr(c['expr'], revised, X[ix])
            evaluations += 1
            held = [r for r in rounds if r['stock'] == stock]
            folds.append(dict(stock=stock, thresholds={str(a):revised[a]['value'] for a in aids},
                statistics=entry_stats(oof, held)))
        neighbors = []
        for aid in aids:
            a = atoms[aid]
            if a['op'] == 'eq':
                continue
            cuts = sorted({float(q['value']) for q in atoms if q['feature'] == a['feature'] and q['op'] in ('gt', 'lt')})
            current = a['value'] if a['op'] == 'between' else [a['value']]
            for coordinate, value in enumerate(current):
                below = [v for v in cuts if v < value]
                above = [v for v in cuts if v > value]
                for adjacent in ([below[-1]] if below else []) + ([above[0]] if above else []):
                    changed = copy.deepcopy(a)
                    if a['op'] == 'between':
                        changed['value'][coordinate] = adjacent
                        if changed['value'][0] >= changed['value'][1]:
                            continue
                    else:
                        changed['value'] = adjacent
                    revised = list(atoms); revised[aid] = changed
                    sig, _ = h.eval_expr(c['expr'], revised, X)
                    evaluations += 1
                    neighbors.append(dict(atom=aid, field=a['name'], before=a['value'], after=changed['value'], statistics=entry_stats(sig, rounds)))
        ablations = []
        for aid in aids:
            expr = [[a for a in b if a != aid] for b in c['expr']]
            sig, _ = h.eval_expr(expr, atoms, X)
            evaluations += 1
            ablations.append(dict(removed=atoms[aid]['name'], statistics=entry_stats(sig, rounds),
                added_entry_hits=sum(bool(sig[i] and not original[i]) for i in entry_indices)))
        masks = [original[entry_indices], oof[entry_indices]]
        results.append(dict(id=c['id'], baseline=entry_stats(original, rounds),
            leave_stock_out=entry_stats(oof, rounds),
            entry_jaccard=float(np.logical_and(*masks).sum()/max(1,np.logical_or(*masks).sum())),
            folds=folds, neighbors=neighbors, ablations=ablations))
    overlap = []
    for i, c in enumerate(candidates):
        a, _ = h.eval_expr(c['expr'], atoms, X); a = a[entry_indices]
        for d in candidates[i+1:]:
            b, _ = h.eval_expr(d['expr'], atoms, X); b = b[entry_indices]
            overlap.append(dict(first=c['id'], second=d['id'], jaccard=float((a&b).sum()/max(1,(a|b).sum()))))
    h.dump('sensitivity.json', dict(scope='A/B W1-W2 only; selected structures fixed; this is threshold sensitivity, not independent cross-validation; no result selected as replacement',
        evaluations=evaluations, candidates=results, overlaps=overlap))
    print(json.dumps(dict(evaluations=evaluations, candidates=[dict(id=r['id'], leave_stock_out=r['leave_stock_out'], jaccard=r['entry_jaccard'], neighbor_min_enrichment=min(s['enrichment'] for n in r['neighbors'] for s in n['statistics'].values())) for r in results]), indent=2))


def source_audit():
    """Cross-source sparse technical values plus all entry identities and chronology."""
    cat = json.loads((h.OUT/'feature-catalog.json').read_text())
    names = {r['name']:i for i,r in enumerate(cat)}
    aliases = {'t_z125':'price_z125', 't_z250':'price_z250'}
    counts = Counter()
    for sample in 'AB':
        with h.db(h.basedir(sample)/'decisions.sqlite') as c:
            technical = {(r['stock_id'],r['trade_date']):dict(r) for r in c.execute('select t.*,s.stock_id from technical_observations t join stocks s using(stock_key)')}
            events = {(r['window_id'],r['stock_id'],r['trade_date']):dict(r) for r in c.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=1')}
            sells = {(r['window_id'],r['stock_id'],r['trade_date']) for r in c.execute("select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=3 and executed_action='SELL'")}
        for label in ('discovery','later'):
            X,keys,rounds = h.load(label)
            for i,k in enumerate(keys):
                if k['sample'] != sample:
                    continue
                e = events[k['window'],k['stock'],k['date']]
                assert k['h_score'] == e['decision_score'] and k['inventory'] == e['inventory_before']
                counts['decision_rows'] += 1
                t = technical.get((k['stock'],k['date']))
                if t is None:
                    continue
                counts['sparse_technical_rows'] += 1
                for name,j in names.items():
                    source = aliases.get(name, 'volume_'+name[2:] if name.startswith('v_') else name)
                    if source not in t or not np.isfinite(X[i,j]):
                        continue
                    assert np.isclose(X[i,j],t[source],rtol=1e-12,atol=1e-12),(k,name,X[i,j],t[source])
                    counts['technical_values'] += 1
            for r in rounds:
                if r['sample'] != sample:
                    continue
                b,end = r['entry'],r['end']
                e = events[r['window'],r['stock'],r['entry_date']]
                assert e['planned_action']=='H' and e['executed_action']=='BUY' and e['inventory_before']==0
                for i in range(b,end+1):
                    k=keys[i]
                    assert (k['sample'],k['window'],k['stock'])==(sample,r['window'],r['stock'])
                    if i>b:
                        assert keys[i-1]['date'] < k['date']
                        assert k['inventory']>0
                if r['closed']:
                    assert (r['window'],r['stock'],r['end_date']) in sells
                if r['decline'] is not None:
                    j=r['decline']
                    assert keys[j]['close']<keys[j-1]['close']
                    assert all(keys[i]['close']>=keys[i-1]['close'] for i in range(b+1,j))
                    assert any(keys[i]['close']>keys[i-1]['close'] for i in range(b+1,j))
                    assert min(k['close'] for k in keys[j:end+1])==r['minimum']
                counts['h_entries_and_round_paths'] += 1
    for name,digest in json.loads((h.OUT/'sources.json').read_text()).items():
        assert h.sha(h.ROOT/name)==digest,name
        counts['unchanged_source_hashes']+=1
    frozen=json.loads((h.OUT/'frozen-candidates.json').read_text())
    for name,digest in frozen['discoveryInputs'].items():
        assert h.sha(h.OUT/name)==digest,name
    counts['unchanged_frozen_discovery_inputs']=len(frozen['discoveryInputs'])
    h.dump('source-audit.json',dict(status='passed',counts=dict(counts),
        scope='A/B all three windows; sparse technical values only where independently present; all H-entry identities and round chronology; source hashes; no C/D/E effects'))
    print(dict(counts))


def case_audit():
    atoms=json.loads((h.OUT/'atoms.json').read_text())
    candidates=json.loads((h.OUT/'frozen-candidates.json').read_text())['candidates']
    summaries=[];examples=[]
    for label in ('discovery','later'):
        X,keys,rounds=h.load(label)
        for c in candidates:
            signal,valid=h.eval_expr(c['expr'],atoms,X)
            cases=json.loads((h.OUT/f'{label}-{c["id"]}-cases.json').read_text())
            groups={}
            for group in sorted({(r['sample'],r['window']) for r in cases}):
                rs=[r for r in cases if (r['sample'],r['window'])==group]
                hits=[r for r in rs if r['entryHit']]
                opp=[r for r in hits if r['opportunity']]
                releases=[r for r in opp if r.get('first_release_change_pct') is not None]
                low=[r['low_price_weighted_release'] for r in opp if r.get('low_price_weighted_release') is not None]
                groups[f'{group[0]}-W{group[1]}']=dict(entry_valid=sum(r['entryValid'] for r in rs),
                    hit_stock_counts=dict(Counter(r['stock'] for r in hits)),
                    opportunity_hits=len(opp),opportunity_released=len(releases),
                    opportunity_released_cheaper=sum(r['first_release_change_pct']<0 for r in releases),
                    opportunity_low_release=float(np.mean(low)) if low else None)
            summaries.append(dict(id=c['id'],label=label,groups=groups))
            if label!='later':continue
            eligible=[r for r in cases if r['opportunity'] and r['entryHit'] and r.get('first_release_change_pct') is not None]
            for mode in ('cheaper','early_dearer'):
                rs=[r for r in eligible if (r['first_release_change_pct']<0 if mode=='cheaper' else r['first_release_change_pct']>0 and r['first_release_before_decline'])]
                if not rs:continue
                rs.sort(key=lambda r:r['first_release_change_pct']);r=rs[len(rs)//2]
                release=next(j for j in range(r['entry']+1,r['end']+1) if not signal[j])
                points=[]
                for role,j in [('entry',r['entry']),('decline',r['decline']),('release',release),('trough',r['trough'])]:
                    points.append(dict(role=role,date=keys[j]['date'],close=keys[j]['close'],signal=bool(signal[j]),
                        fields={atoms[a]['name']:float(X[j,atoms[a]['feature']]) for branch in c['expr'] for a in branch}))
                examples.append(dict(candidate=c['id'],type=mode,id=r['id'],name=r['name'],
                    entry_date=r['entry_date'],entry_price=r['entry_price'],release_date=r['first_release_date'],
                    release_price=r['first_release_price'],release_change=r['first_release_change_pct'],
                    minimum=r['minimum'],min_date=r['min_date'],points=points))
    h.dump('case-audit.json',summaries)
    h.dump('case-examples.json',dict(selection='W3 opportunity hits with available release; median first-release change within cheaper / pre-decline dearer subset, never maximum outcome',examples=examples))


def path_context():
    result=[]
    for label in ('discovery','later'):
        _,keys,rounds=h.load(label)
        for r in rounds:
            b,e,d=r['entry'],r['end'],r['decline']
            peak_end=d if d is not None else e+1
            peak=max(keys[j]['close'] for j in range(b,peak_end))
            low_dates=[];segments=[]
            if d is not None:
                low_dates=[keys[j]['date'] for j in range(d,e+1) if keys[j]['close']==r['minimum']]
                for j in range(d,e+1):
                    move=keys[j]['close']-keys[j-1]['close']
                    direction='rise' if move>0 else 'fall' if move<0 else 'flat'
                    if not segments or segments[-1]['direction']!=direction:
                        segments.append(dict(direction=direction,start_date=keys[j-1]['date'],start_price=keys[j-1]['close']))
                    segments[-1].update(end_date=keys[j]['date'],end_price=keys[j]['close'])
            result.append(dict(id=r['id'],label=label,peak_until_first_decline=peak,
                peak_dates=[keys[j]['date'] for j in range(b,peak_end) if keys[j]['close']==peak],
                all_post_decline_minimum_dates=low_dates,direction_segments_after_decline=segments))
    h.dump('path-context.json',result)


def stock_groups():
    mapping={}
    for sample in 'AB':
        with h.db(h.basedir(sample)/'decisions.sqlite') as c:
            mapping.update({(sample,r['stock_id']):r['group_name'] for r in c.execute('select stock_id,group_name from stocks')})
    result=[]
    candidates=json.loads((h.OUT/'frozen-candidates.json').read_text())['candidates']
    for label in ('discovery','later'):
        for c in candidates:
            cases=json.loads((h.OUT/f'{label}-{c["id"]}-cases.json').read_text())
            groups={}
            for sample,window,group in sorted({(r['sample'],r['window'],mapping[r['sample'],r['stock']]) for r in cases}):
                rs=[r for r in cases if r['sample']==sample and r['window']==window and mapping[sample,r['stock']]==group]
                pos=[r for r in rs if r['opportunity']]
                other=[r for r in rs if r['closed'] and not r['bottom_boundary'] and not r['opportunity']]
                groups[f'{sample}-W{window}-{group}']=dict(rounds=len(rs),hits=sum(r['entryHit'] for r in rs),
                    targets=len(pos),target_hits=sum(r['entryHit'] for r in pos),
                    other=len(other),other_hits=sum(r['entryHit'] for r in other))
            result.append(dict(id=c['id'],label=label,groups=groups))
    h.dump('stock-group-review.json',dict(note='All trades here are H entry type; stock group is a separate Baseline grouping',results=result))


if __name__ == '__main__':
    main()
    source_audit()
    case_audit()
    path_context()
    stock_groups()
