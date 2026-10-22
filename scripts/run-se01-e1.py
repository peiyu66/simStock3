#!/usr/bin/env python3
"""Run one authorized E1 sample/window in the dedicated isolated Simulator.

This consumes a source-verified Debug build, keeps original inputs/reports intact,
and never publishes, adopts parameters or records a formal DecisionBase.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.peiyou.simStock3'
DEVICE = 'E967D01E-880D-4331-A83F-DB1FBD6C36BC'
MARKET_RELATIVE = 'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af/market-daily.csv'
MARKET_SHA = '558883f85355b49c1c4402b4346d9a4939411bea69d405275c2b42aa55bb8da4'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def allocated(path):
    if not path.exists():
        return 0
    return sum(p.stat().st_blocks * 512 for p in path.rglob('*') if p.is_file() and not p.is_symlink())


def stage(source, target, expected):
    assert sha(source) == expected, f'Source mismatch: {source}'
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        shutil.copy2(source, target)
    assert sha(target) == expected, f'Existing staged input differs: {target}'


def verify_report(baseline, manifest, run_id, sample, rule_commit):
    for obj in [baseline, manifest]:
        assert obj['runID'] == run_id and obj['sampleID'] == sample, 'Report identity mismatch'
        assert obj['ruleCommit'] == rule_commit and obj['dataRuleVersion'] == 'T4/S65', 'Rule identity mismatch'
        diagnostic = obj['diagnostic']
        assert diagnostic['mode'] == 'se01-e1-research'
        assert diagnostic['baseRuleCommit'] == '8932a9d78fb2c2e4376138e4dce1e2419603db50'
        assert diagnostic['formalStrategy'] == 'false' and diagnostic['formalBaseline'] == 'false'
        assert diagnostic['cacheRuleCommit'] == rule_commit
        assert 'target-period-only' in diagnostic['validityScope']
    assert baseline['marketInput']['marketTechnicalVersion'] == '7'
    assert isinstance(baseline['combinedScore'], (int, float)) and math.isfinite(baseline['combinedScore']), 'Missing/nonfinite diagnostic score'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sample', required=True, choices=list('ABCDE'))
    p.add_argument('--window', required=True, choices=['fixed3y', 'fullstress'])
    p.add_argument('--run-id', required=True)
    p.add_argument('--rule-commit', required=True)
    p.add_argument('--source-root', required=True, type=Path)
    p.add_argument('--app', required=True, type=Path)
    p.add_argument('--build-evidence', required=True, type=Path)
    p.add_argument('--e1-mode', required=True, choices=['control', 'legacy', 'unit'])
    p.add_argument('--timeout', type=int, default=900)
    p.add_argument('--stall-timeout', type=int, default=180)
    args = p.parse_args()
    args.maturity_probe = False
    assert re.fullmatch(r'[a-z0-9-]{1,80}', args.run_id) and args.run_id.startswith('e1-')
    assert re.fullmatch(r'[a-f0-9]{40}', args.rule_commit)
    maximum_timeout = 3600 if args.maturity_probe else 1800
    assert 1 <= args.stall_timeout <= args.timeout <= maximum_timeout
    if args.maturity_probe:
        assert args.sample == 'A' and args.window == 'fixed3y' and args.run_id.startswith('p5-maturity-')
    diagnostic_id = args.run_id
    run_id = f'update-cycle-{diagnostic_id}-{args.sample.lower()}-{"full" if args.window == "fullstress" else "fixed3y"}-{args.rule_commit[:12]}'
    output = ROOT / 'exports/update-cycle-e1' / diagnostic_id
    output.mkdir(parents=True, exist_ok=False)
    result = dict(status='running', runID=run_id, diagnosticID=diagnostic_id, sample=args.sample, window=args.window,
                  ruleCommit=args.rule_commit, dataRules='T4/S65', marketTechnicalVersion=7,
                  strategy='E1 research only: S-E01 '+args.e1_mode, e1Mode=args.e1_mode, baseRuleCommit='8932a9d78fb2c2e4376138e4dce1e2419603db50',
                  formalStrategyValidated=False, maturityProbe=args.maturity_probe, commands=[])
    started = time.monotonic()
    launched = False
    launch = None
    internal = None
    run = None
    progress = None
    installed_app = None
    launch_log = None

    def command(label, argv, allow_failure=False):
        log = output / (label + '.log')
        with log.open('w') as stream:
            r = subprocess.run(argv, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=120)
        result['commands'].append(dict(label=label, argv=list(map(str, argv)), exit=r.returncode, log=str(log)))
        if not allow_failure and r.returncode:
            raise RuntimeError(f'{label}: exit {r.returncode}; {log}')
        return log.read_text().strip()

    def budget():
        usage = allocated(ROOT / 'exports/update-cycle-p1') + allocated(ROOT / 'exports/update-cycle-p5') + allocated(ROOT / 'exports/update-cycle-e1')
        if internal:
            usage += allocated(internal)
        if installed_app:
            usage += allocated(installed_app)
        free = shutil.disk_usage(ROOT).free
        result['resourceBytes'] = dict(allocated=usage, free=free, cap=32 * 1024**3)
        assert usage <= 32 * 1024**3 and free >= 8 * 1024**3, 'Disk budget exceeded; preserve evidence'

    try:
        head = command('head', ['git', 'rev-parse', 'HEAD'])
        assert head == args.rule_commit, 'Exact candidate commit required'
        command('clean-source', ['git', 'diff', '--exit-code', 'HEAD', '--', 'simStock3', 'simStock3.xcodeproj'])
        evidence = json.loads(args.build_evidence.read_text())
        assert evidence['status'] == 'passed', 'Successful build/test evidence required'
        hashes = evidence['buildInputHashes']
        source_files = {str(x.relative_to(ROOT)) for folder in ['simStock3', 'simStock3.xcodeproj']
                        for x in (ROOT / folder).rglob('*') if x.is_file()
                        and 'xcuserdata' not in x.parts and x.name != '.DS_Store'}
        assert source_files == hashes.keys(), 'Build evidence input set differs'
        tracked = set(command('tracked-build-inputs', ['git', '-c', 'core.quotepath=false', 'ls-files', '--', 'simStock3', 'simStock3.xcodeproj']).splitlines())
        assert source_files <= tracked, 'Uncommitted build input cannot claim the candidate commit'
        for name in source_files:
            assert sha(ROOT / name) == hashes[name], f'Build source mismatch: {name}'
        for name in ['simStock3', 'simStock3.debug.dylib']:
            assert sha(args.app / name) == evidence['productHashes'][name], f'App not from verified build: {name}'
        result['buildEvidence'] = dict(path=str(args.build_evidence), sha256=sha(args.build_evidence))
        devices = json.loads(command('devices', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
        matches = [d for group in devices['devices'].values() for d in group if d['udid'] == DEVICE]
        assert len(matches) == 1 and matches[0]['name'] == 'simStock3 Contract Tests 20261007'
        assert matches[0]['state'] == 'Booted', 'Boot the dedicated test device explicitly first'
        command('terminate-previous', ['xcrun', 'simctl', 'terminate', DEVICE, BUNDLE], allow_failure=True)
        command('install', ['xcrun', 'simctl', 'install', DEVICE, str(args.app)])
        data = Path(command('container', ['xcrun', 'simctl', 'get_app_container', DEVICE, BUNDLE, 'data']))
        app = Path(command('installed-app', ['xcrun', 'simctl', 'get_app_container', DEVICE, BUNDLE, 'app']))
        assert DEVICE in data.parts, 'Dedicated container identity mismatch'
        installed_app = app
        result['installedImages'] = {}
        for name in ['simStock3', 'simStock3.debug.dylib']:
            assert sha(args.app / name) == sha(app / name), f'Installed image mismatch: {name}'
            result['installedImages'][name] = sha(app / name)
        internal = data / 'Documents/InternalBacktest'
        result['container'] = str(data)
        frozen = args.source_root / 'exports/price-update-resume-20261016/frozen-inputs'
        sources = json.loads((frozen / 'sources.json').read_text())
        prefix = f'sample-{args.sample.lower()}-2017-07-22-t3-baseline-v3/'
        selected = [x for x in sources if x['relative'].startswith(prefix)]
        assert len(selected) == 2 and any(x['relative'].endswith('/baseline.store') for x in selected)
        for row in selected:
            stage(frozen / row['relative'], internal / row['relative'], row['sha256'])
        input_store = internal / prefix / 'baseline.store'
        for suffix in ['-wal', '-shm']:
            assert not Path(str(input_store) + suffix).exists(), 'Unexpected frozen input sidecar; preserve and inspect'
        input_digest = hashlib.sha256(b'store' + input_store.read_bytes() + b'-walabsent').hexdigest()
        result['stagedInputStoreDigest'] = input_digest
        stage(args.source_root / MARKET_RELATIVE, internal / 'Research/Market/market-daily.csv', MARKET_SHA)
        result['inputSources'] = selected
        result['marketSHA256'] = MARKET_SHA
        p5_name = 'p5-maturity-a-fixed-03' if (args.sample, args.window) == ('A', 'fixed3y') else f'p5-{args.sample.lower()}-{"fixed" if args.window == "fixed3y" else "full"}-01'
        p5 = ROOT / 'exports/update-cycle-p5' / p5_name
        parent = json.loads((p5 / 'summary.json').read_text())
        assert parent['status'] == 'passed' and parent['ruleCommit'] == result['baseRuleCommit']
        parent_baseline = json.loads((p5 / 'report/baseline.json').read_text())
        e1_input = internal / 'E1' / f'{args.sample.lower()}-{"fixed" if args.window == "fixed3y" else "full"}'
        source_manifest = dict(baseRule=result['baseRuleCommit'], sample=args.sample, fullWindow=args.window=='fullstress', stores={})
        result['p5Sources'] = {}
        for index, start in enumerate(parent_baseline['periodStarts']):
            name = 'browse.store' if index == 0 else 'period-'+start.replace('/', '')+'.store'
            source_store = p5 / 'report' / name
            target_store = e1_input / name
            for suffix in ['', '-wal']:
                original = Path(str(source_store)+suffix)
                if original.exists():
                    digest = sha(original); stage(original, Path(str(target_store)+suffix), digest)
                    result['p5Sources'][str(original)] = digest
                else:
                    assert not Path(str(target_store)+suffix).exists()
            hasher = hashlib.sha256()
            for suffix in ['', '-wal']:
                hasher.update(('store' if not suffix else suffix).encode())
                f = Path(str(target_store)+suffix)
                hasher.update(f.read_bytes() if f.exists() else b'absent')
            source_manifest['stores'][start] = dict(file=name, digest=hasher.hexdigest())
        source_text = json.dumps(source_manifest, sort_keys=True, indent=2)
        manifest_path = e1_input / 'sources.json'
        if manifest_path.exists(): assert manifest_path.read_text() == source_text
        else: manifest_path.write_text(source_text)
        (output / 'p5-period-sources.json').write_text(source_text)
        run = internal / 'Runs' / run_id
        progress = internal / 'Diagnostics' / run_id / 'progress.log'
        assert not run.exists() and not progress.exists(), 'Run already exists; never overwrite or silently resume'
        failure = internal / '.last-run-failure.txt'
        old_failure = failure.read_bytes() if failure.exists() else None
        old_failure_identity = (failure.stat().st_mtime_ns, old_failure) if failure.exists() else None
        if old_failure:
            (output / 'previous-failure-marker.txt').write_bytes(old_failure)
        budget()
        argv = ['xcrun', 'simctl', 'launch', DEVICE, BUNDLE, '--run-internal-backtest-report',
                '--update-cycle-diagnostic', '--update-cycle-diagnostic-id', diagnostic_id,
                '--nine-year-ab-baseline', '--sample-' + args.sample.lower(),
                '--retain-period-stores', '--rule-commit', args.rule_commit, '--se01-e1-mode', args.e1_mode]
        if args.window == 'fullstress':
            argv += ['--full-window-stress']
        if args.maturity_probe:
            argv += ['--update-cycle-maturity-probe']
        launch_log = (output / 'launch.log').open('w')
        launch = subprocess.Popen(argv, cwd=ROOT, stdout=launch_log, stderr=subprocess.STDOUT)
        launched = True
        result['commands'].append(dict(label='launch', argv=argv, log=str(output / 'launch.log')))
        last_progress = last_notice = time.monotonic()
        previous = None
        while not (run / '.complete').exists():
            now = time.monotonic()
            if failure.exists() and (failure.stat().st_mtime_ns, failure.read_bytes()) != old_failure_identity:
                raise RuntimeError(failure.read_text())
            if launch.poll() not in (None, 0):
                raise RuntimeError('Simulator launch failed; see launch.log')
            state = (progress.stat().st_mtime_ns, progress.stat().st_size) if progress.exists() else None
            if state != previous:
                previous, last_progress = state, now
                if progress.exists():
                    progress_text = progress.read_text()
                    peaks = re.findall(r'peakRSSBytes=(\d+)', progress_text)
                    if peaks:
                        result['peakRSSBytes'] = max(map(int, peaks))
                        result['appRSSLimitBytes'] = 2 * 1024**3
                        if result['peakRSSBytes'] > result['appRSSLimitBytes']:
                            raise MemoryError('Diagnostic App exceeded 2 GiB RSS guard; preserving partial outputs')
                    lines = progress_text.splitlines()
                    print(lines[-1] if lines else 'Progress file created', flush=True)
            if now - last_notice >= 30:
                budget()
                print(f'E1 {args.e1_mode} {args.sample} {args.window}: elapsed={now-started:.0f}s, last progress={now-last_progress:.0f}s ago', flush=True)
                last_notice = now
            if now - started > args.timeout or now - last_progress > args.stall_timeout:
                raise TimeoutError('Diagnostic stalled/timed out; preserving partial outputs')
            time.sleep(1)
        if launch.poll() is None:
            launch.wait(timeout=30)
        launch_log.close()
        assert (run / '.complete').read_text().strip() == run_id
        for name in ['baseline.json', 'manifest.json', 'periods.csv', 'report.html', 'browse.store']:
            assert (run / name).is_file(), f'Missing output {name}'
        baseline = json.loads((run / 'baseline.json').read_text())
        manifest = json.loads((run / 'manifest.json').read_text())
        verify_report(baseline, manifest, run_id, args.sample, args.rule_commit)
        for obj in [baseline, manifest]:
            assert obj['diagnostic']['inputStoreSHA256'] == input_digest, 'App input differs from verified raw store'
        for row in selected:
            assert sha(frozen / row['relative']) == sha(internal / row['relative']) == row['sha256'], 'Input changed during run'
        for suffix in ['-wal', '-shm']:
            assert not Path(str(input_store) + suffix).exists(), 'Frozen input unexpectedly acquired a sidecar'
        assert baseline['diagnostic']['e1Mode'] == args.e1_mode
        assert (run / 'se01-events.json').is_file()
        assert all(sha(Path(path)) == digest for path, digest in result['p5Sources'].items()), 'Frozen P5 input changed'
        assert progress and progress.exists()
        traces = re.findall(r'TRACE .*?T ordinary=(\d+) path=(\d+) S=(\d+)', progress.read_text())
        assert len(traces) == 10 * len(parent_baseline['periodStarts'])
        assert all(int(t)==0 and int(p)==0 for t,p,_ in traces), 'E1 unexpectedly rewrote T'
        result['simulationDays'] = sum(int(count) for _,_,count in traces)
        if args.maturity_probe:
            probe = run / 'MaturityProbe/report.json'
            assert probe.is_file(), 'Missing maturity comparison artifact'
            comparison = json.loads(probe.read_text())
            assert comparison['comparisonCompleted'] is True, 'Maturity comparison incomplete'
            assert comparison['ruleCommit'] == args.rule_commit and comparison['dataRules'] == 'T4/S65'
            assert comparison['marketVersion'] == 7 and comparison['formalStrategy'] is False
            assert comparison['formalBaseline'] is False and len(comparison['stocks']) == 10
            assert len(comparison['ordinaryFieldNames']) == 65 and len(comparison['pathFieldNames']) == 5
            # S/ordinary differences are diagnostic findings, not runner failures
            # and never an implicit plan-acceptance or new-parameter approval.
            result['maturityComparison'] = {k: comparison[k] for k in
                ['boundedPathIdentical', 'simulationIdentical', 'ordinaryIdentical']}
            result['maturityProbeReport'] = str(output / 'report/MaturityProbe/report.json')
            result['maturityProbeRequiresReview'] = True
        for store in run.rglob('*.store'):
            with sqlite3.connect(store.as_uri() + '?mode=ro', uri=True) as db:
                assert db.execute('pragma integrity_check').fetchone()[0] == 'ok', store
        # End the run-local process before copying SQLite/WAL for consistent artifacts.
        command('terminate-complete', ['xcrun', 'simctl', 'terminate', DEVICE, BUNDLE])
        shutil.copytree(run, output / 'report')
        if progress.exists():
            shutil.copy2(progress, output / 'progress.log')
        result['combinedScore'] = baseline['combinedScore']
        result['status'] = 'passed'
        result['report'] = str(output / 'report/report.html')
        budget()
    except BaseException as error:
        result['status'] = 'failed'
        result['error'] = repr(error)
        try:
            if launch and launch.poll() is None:
                launch.terminate()
                launch.wait(timeout=10)
            if launched:
                command('terminate-failed', ['xcrun', 'simctl', 'terminate', DEVICE, BUNDLE], allow_failure=True)
            if run and run.exists():
                shutil.copytree(run, output / 'partial-report')
                result['partialReport'] = str(output / 'partial-report')
            if progress and progress.exists():
                shutil.copy2(progress, output / 'progress.log')
        except Exception as cleanup_error:
            result['cleanupError'] = repr(cleanup_error)
    finally:
        if launch_log and not launch_log.closed:
            launch_log.close()
        result['seconds'] = time.monotonic() - started
        (output / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(json.dumps({k:result[k] for k in ['status','runID','combinedScore','seconds','error'] if k in result}, ensure_ascii=False), flush=True)
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
