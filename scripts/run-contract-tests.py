#!/usr/bin/env python3
"""Run the existing migration/replay contracts on an explicitly isolated Simulator."""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SELECTION = Path(__file__).with_name('contract-tests.json')
DEVICE_PREFIX = 'simStock3 Contract Tests '


def selected_tests(root=ROOT, selection=SELECTION):
    config = json.loads(selection.read_text())
    if config.get('schemaVersion') != 1 or config.get('target') != 'simStock3Tests':
        raise ValueError('Unsupported test selection')
    selected = []
    for suite, cases in config['suites'].items():
        if not re.fullmatch(r'\w+Tests', suite) or not cases:
            raise ValueError('Invalid/empty suite')
        source = (root / 'simStock3Tests' / (suite + '.swift')).read_text()
        available = re.findall(r'^\s*func\s+(test\w+)\s*\(', source, re.M)
        for case in cases:
            if not re.fullmatch(r'test\w+', case) or available.count(case) != 1:
                raise ValueError('Test missing or ambiguous in source: ' + suite + '/' + case)
            selected.append(config['target'] + '/' + suite + '/' + case)
    if not selected or len(selected) != len(set(selected)):
        raise ValueError('Empty or duplicate selection')
    return selected


def isolated_device(payload, udid):
    matches = [(runtime, d) for runtime, devices in payload['devices'].items()
               for d in devices if d['udid'] == udid]
    if len(matches) != 1:
        raise ValueError('Simulator UDID not found uniquely')
    runtime, device = matches[0]
    if not device.get('isAvailable') or not device['name'].startswith(DEVICE_PREFIX):
        raise ValueError('Use a dedicated Simulator named "' + DEVICE_PREFIX + '<label>"')
    if 'iOS-' not in runtime:
        raise ValueError('An iOS Simulator is required')
    return dict(device, runtime=runtime)


def test_results(payload, selected):
    observed = collections.defaultdict(list)
    def visit(node):
        if node.get('nodeType') == 'Test Case':
            identifier = node.get('nodeIdentifier', '').removesuffix('()')
            if identifier.count('/') == 1:
                identifier = 'simStock3Tests/' + identifier
            observed[identifier].append(node.get('result', 'unknown'))
        for child in node.get('children', []):
            visit(child)
    for node in payload['testNodes']:
        visit(node)
    results = []
    for name in selected:
        values = observed.get(name, [])
        status = ('passed' if values == ['Passed'] else
                  'failed' if 'Failed' in values else 'not-run')
        results.append(dict(test=name, status=status, reported=values))
    unexpected = sorted(set(observed) - set(selected))
    passed = bool(selected) and not unexpected and all(x['status'] == 'passed' for x in results)
    return dict(status='passed' if passed else 'failed', cases=results, unexpected=unexpected,
                counts=dict(collections.Counter(x['status'] for x in results)))


class Runner:
    def __init__(self, output, timeout, stall_timeout):
        self.output = output
        self.deadline = time.monotonic() + timeout
        self.stall_timeout = stall_timeout
        self.commands = []

    def run(self, phase, command):
        if time.monotonic() >= self.deadline:
            raise TimeoutError('Total timeout before ' + phase)
        log = self.output / (phase + '.log')
        self.commands.append(dict(phase=phase, command=command, log=str(log)))
        print('START', phase, '|', log, flush=True)
        with log.open('wb') as stream:
            process = subprocess.Popen(command, cwd=ROOT, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            changed = heartbeat = time.monotonic()
            size = 0
            try:
                while process.poll() is None:
                    now = time.monotonic()
                    current = log.stat().st_size
                    if current != size:
                        changed, size = now, current
                    if now >= self.deadline:
                        raise TimeoutError('Total timeout during ' + phase)
                    if now - changed >= self.stall_timeout:
                        raise TimeoutError('No log progress during ' + phase)
                    if now - heartbeat >= 15:
                        print('PROGRESS', phase, '| log bytes:', size,
                              '| unchanged seconds:', round(now - changed), flush=True)
                        heartbeat = now
                    time.sleep(0.2)
            except BaseException:
                # Stop only the process group started for this command.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                except ProcessLookupError:
                    pass
                raise
        print('END', phase, '| exit:', process.returncode, flush=True)
        return process.returncode, log

    def json(self, phase, command):
        code, log = self.run(phase, command)
        if code:
            raise RuntimeError(phase + ' failed; see ' + str(log))
        return json.loads(log.read_text())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--list', action='store_true', help='Validate and print selection; no Xcode/Simulator calls')
    parser.add_argument('--simulator', help='Explicit dedicated Simulator UDID (never a default device)')
    parser.add_argument('--build-dir', type=Path, help='Dedicated DerivedData directory; Xcode reuses incremental outputs')
    parser.add_argument('--output', type=Path, help='New directory for logs, xcresult and summary.json')
    parser.add_argument('--timeout', type=int, default=900, help='Total command deadline, seconds (max 1800)')
    parser.add_argument('--stall-timeout', type=int, default=180, help='Stop if a phase produces no log progress, seconds')
    args = parser.parse_args(argv)
    if not 1 <= args.stall_timeout <= args.timeout <= 1800:
        parser.error('Require 1 <= stall-timeout <= timeout <= 1800')
    try:
        selected = selected_tests()
    except (ValueError, KeyError, OSError) as error:
        print('NOT RUN:', error, file=sys.stderr)
        return 2
    print('Selected', len(selected), 'existing cases:', flush=True)
    print('\n'.join(selected), flush=True)
    if args.list:
        return 0
    if not all([args.simulator, args.build_dir, args.output]):
        parser.error('--simulator, --build-dir and --output are required')
    if not re.fullmatch(r'[0-9A-Fa-f-]{36}', args.simulator):
        parser.error('Invalid Simulator UDID')
    output, build = args.output.resolve(), args.build_dir.resolve()
    if output.exists() or output == build or output.is_relative_to(build):
        parser.error('Output must be a new directory outside build-dir')
    # A dedicated build directory can be reused only after this entry created it.
    marker = build / '.simstock-contract-tests'
    if build.exists() and not marker.is_file():
        parser.error('Existing build-dir was not created by this entry; choose a new dedicated path')
    output.mkdir(parents=True)
    started = time.monotonic()
    runner = Runner(output, args.timeout, args.stall_timeout)
    result = dict(status='not-run', selected=selected, cases=[dict(test=x, status='not-run') for x in selected])
    code = 2
    try:
        device = isolated_device(runner.json('devices', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j']), args.simulator)
        result['device'] = {k: device[k] for k in ['udid', 'name', 'runtime']}
        build.mkdir(parents=True, exist_ok=True)
        marker.write_text(str(ROOT) + '\n')
        if device['state'] != 'Booted':
            if runner.run('boot', ['xcrun', 'simctl', 'boot', args.simulator])[0]:
                raise RuntimeError('Simulator boot failed')
        if runner.run('boot-ready', ['xcrun', 'simctl', 'bootstatus', args.simulator, '-b'])[0]:
            raise RuntimeError('Simulator bootstatus failed')
        bundle = output / 'tests.xcresult'
        command = ['xcodebuild', 'test', '-project', 'simStock3.xcodeproj', '-scheme', 'simStock3',
                   '-configuration', 'Debug', '-destination', 'platform=iOS Simulator,id=' + args.simulator,
                   '-destination-timeout', '60', '-derivedDataPath', str(build), '-resultBundlePath', str(bundle),
                   '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1',
                   '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '60',
                   '-maximum-test-execution-time-allowance', '120']
        command.extend('-only-testing:' + x for x in selected)
        exit_code, _ = runner.run('xcodebuild', command)
        result['xcodebuildExitCode'] = exit_code
        if not bundle.exists():
            raise RuntimeError('No xcresult; cases are not verified')
        payload = runner.json('test-results', ['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(bundle), '--compact'])
        result.update(test_results(payload, selected))
        result['xcresult'] = str(bundle)
        if exit_code:
            result['status'] = 'failed'
        code = 0 if result['status'] == 'passed' else 1
    except TimeoutError as error:
        result.update(status='incomplete', error=str(error))
        code = 124
    except (KeyboardInterrupt, InterruptedError):
        result.update(status='incomplete', error='Interrupted; no success claimed')
        code = 130
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        result.update(status='incomplete', error=str(error))
        code = 2
    finally:
        result.update(elapsedSeconds=round(time.monotonic() - started, 3), commands=runner.commands,
                      selectionSHA256=hashlib.sha256(SELECTION.read_bytes()).hexdigest(), exitCode=code)
        (output / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        for case in result['cases']:
            print(case['status'].upper(), case['test'])
        print('RESULT', result['status'], '|', output / 'summary.json', flush=True)
    return code


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(InterruptedError()))
    sys.exit(main())
