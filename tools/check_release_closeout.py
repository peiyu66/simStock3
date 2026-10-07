#!/usr/bin/env python3
"""Read-only release/closeout evidence checks. Never build, replay or publish."""
import argparse
import hashlib
import html
import io
import json
from pathlib import Path
import plistlib
import re
import sqlite3
import subprocess
import sys
from urllib.parse import parse_qs, urlparse
import zipfile


class Unknown(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def asset_identity(manifest, ipa, expected, urls):
    item = plistlib.loads(manifest)['items'][0]
    require(item['metadata']['bundle-identifier'] == expected['bundleID'], 'manifest bundle ID mismatch')
    require(str(item['metadata']['bundle-version']) == str(expected['build']), 'manifest build mismatch')
    packages = [a['url'] for a in item['assets'] if a['kind'] == 'software-package']
    require(packages == [urls['ipa']], 'manifest IPA URL mismatch')
    with zipfile.ZipFile(io.BytesIO(ipa)) as archive:
        names = [n for n in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info.plist', n)]
        require(len(names) == 1, 'IPA must have one main app')
        info = plistlib.loads(archive.read(names[0]))
    for key, value in [('CFBundleIdentifier', expected['bundleID']),
                       ('CFBundleShortVersionString', expected['appVersion']),
                       ('CFBundleVersion', str(expected['build']))]:
        require(str(info[key]) == value, 'IPA ' + key + ' mismatch')
    require('iPhoneOS' in info.get('CFBundleSupportedPlatforms', []), 'IPA is not an iPhoneOS distribution')


def install_link(page, manifest_url):
    links = re.findall(r'''href=["']([^"']+)["']''', page)
    targets = []
    for link in links:
        parsed = urlparse(html.unescape(link))
        if parsed.scheme == 'itms-services':
            query = parse_qs(parsed.query)
            if query.get('action') == ['download-manifest']:
                targets.extend(query.get('url', []))
    require(targets and all(t == manifest_url for t in targets), 'missing or unexpected Pages installation target')


def app_path(path):
    return path.startswith(('simStock3/', 'simStock3.xcodeproj/', 'release/')) and path != 'release/closeout-profile.json'


class Checker:
    def __init__(self, root, profile, documentation_commit='HEAD'):
        self.root = Path(root).resolve()
        self.profile = profile
        self.documentation_commit = documentation_commit
        self.checks = []

    def path(self, value):
        p = (self.root / value).resolve()
        require(p.is_relative_to(self.root), 'evidence path escapes repository')
        return p

    def read(self, value):
        return self.path(value).read_text()

    def payload(self, value):
        return json.loads(self.read(value))

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'core.quotepath=false', *args], cwd=self.root, stderr=subprocess.PIPE, timeout=30).decode().strip()

    def check(self, name, fn, scope='offline'):
        try:
            detail = fn()
            self.checks.append(dict(id=name, scope=scope, status='passed', detail=detail or '一致'))
        except (Unknown, FileNotFoundError) as error:
            self.checks.append(dict(id=name, scope=scope, status='unknown', detail=str(error)))
        except (OSError, subprocess.SubprocessError) as error:
            self.checks.append(dict(id=name, scope=scope, status='blocked', detail=type(error).__name__ + ': operation unavailable'))
        except (ValueError, KeyError, TypeError, IndexError, AttributeError, sqlite3.Error, zipfile.BadZipFile) as error:
            self.checks.append(dict(id=name, scope=scope, status='failed', detail=str(error)))

    def commits(self):
        p = self.profile
        commits = {k: p[k] for k in ('ruleCommit', 'releaseCommit')}
        for key, value in commits.items():
            require(re.fullmatch('[0-9a-f]{40}', value), key + ' must be a full commit')
            require(self.git('rev-parse', '--verify', value + '^{commit}') == value, key + ' does not resolve exactly')
        docs = self.git('rev-parse', '--verify', self.documentation_commit + '^{commit}')
        for older, newer in [(p['ruleCommit'], p['releaseCommit']), (p['releaseCommit'], docs)]:
            require(self.git('merge-base', older, newer) == older, 'commit ancestry mismatch')
        changed = self.git('diff', '--name-only', p['releaseCommit'], docs).splitlines()
        require(not [x for x in changed if app_path(x)], 'App/install changes exist after release commit')
        dirty = self.git('diff', '--name-only', 'HEAD').splitlines()
        dirty += self.git('ls-files', '--others', '--exclude-standard').splitlines()
        require(not [x for x in dirty if app_path(x)], 'unreleased App/install worktree changes')
        return dict(**commits, documentationCommit=docs, documentationChanges=len(changed))

    def source_versions(self):
        p = self.profile
        for ref in [None, p['releaseCommit']]:
            read = self.read if ref is None else lambda f: self.git('show', ref + ':' + f)
            project = read('simStock3.xcodeproj/project.pbxproj')
            for key, expected in [('MARKETING_VERSION', p['appVersion']), ('CURRENT_PROJECT_VERSION', str(p['build']))]:
                require(set(re.findall(key + r' = ([^;]+);', project)) == {expected}, key + ' differs across configurations/profile')
            require(self.data_rules(read('simStock3/technical.swift')) == p['dataRules'], 'source T/S mismatch')
            require('"' + p['ruleVersion'] + '"' in read('simStock3/InternalBacktestReport.swift'), 'strategy identifier absent from source')
        require(self.data_rules(self.git('show', p['ruleCommit'] + ':simStock3/technical.swift')) == p['dataRules'], 'rule commit T/S mismatch')

    def documentation_worktree(self):
        paths = set(self.profile['documentationPaths'])
        changed = set(self.git('diff', '--name-only', self.documentation_commit).splitlines())
        changed.update(self.git('ls-files', '--others', '--exclude-standard').splitlines())
        pending = sorted(changed & paths)
        if pending:
            raise Unknown('本機文件尚未包含於指定文件 commit：' + ', '.join(pending))
        return '指定文件與檢查器均屬於本次文件 commit；其他工作樹差異不混入'

    @staticmethod
    def data_rules(source):
        values = [re.search(r'current' + kind + r'StateVersion\s*=\s*(\d+)', source).group(1)
                  for kind in ('Technical', 'Simulation')]
        return 'T' + values[0] + '/S' + values[1]

    def identity(self, payload, sample):
        p = self.profile
        for key, value in [('ruleCommit', p['ruleCommit']), ('dataRuleVersion', p['dataRules']),
                           ('ruleVersion', p['ruleVersion']), ('sampleID', sample),
                           ('through', p['through']), ('moneyBaseWan', p['moneyBaseWan']),
                           ('automaticInvestments', p['automaticInvestments'])]:
            require(payload.get(key) == value, key + ' mismatch')

    def report(self, sample, window, directory):
        p = self.profile
        folder = self.path(directory)
        m = self.payload(directory + '/manifest.json')
        b = self.payload(directory + '/baseline.json')
        for data in (m, b):
            self.identity(data, sample)
            require(data['runID'] == folder.name, 'run ID / directory mismatch')
            require(data['periodStarts'] == p['periodStarts'][window], 'period starts mismatch')
        require('-' + p['baseline'] + '-' in folder.name and '-' + window + '-' in folder.name, 'baseline/window directory mismatch')
        require((folder / '.complete').read_text().strip() == m['runID'], 'report completion mismatch')
        require({'report.html', 'baseline.json', 'manifest.json', 'periods.csv'} <= set(m['reportFiles']), 'report file list incomplete')
        for name in [*m['reportFiles'], m['browseStore']]:
            require(self.path(directory + '/' + name).is_file(), 'missing report artifact: ' + name)
        report = (folder / 'report.html').read_text()
        require(all(value in report for value in (p['ruleCommit'], p['dataRules'], p['ruleVersion'])), 'HTML identity mismatch')
        history = self.read(p['historyDocument'])
        rows = [line for line in history.splitlines() if line.startswith('| ' + p['strategy'] + '／' + p['baseline'] + ' |')]
        label = '固定三年' if window == 'fixed3y' else '全期間'
        rows = [line for line in rows if '| ' + label + ' |' in line]
        require(len(rows) == 1, 'missing/duplicate history index row for ' + label)
        cell = rows[0].split('|')[3 + p['samples'].index(sample)]
        require(directory + '/report.html' in cell, 'history sample/report mismatch')
        score = re.search(r'`([-+\d.]+)`', cell)
        require(score and score.group(1) == format(b['combinedScore'], '.3f'), 'history score mismatch')
        return dict(runID=m['runID'], score=b['combinedScore'])

    def decision_base(self, sample, directory):
        p = self.profile
        m = self.payload(directory + '/manifest.json')
        self.identity(m, sample)
        require(m['formatVersion'] == p['decisionBaseFormat'], 'DB format mismatch')
        require(self.path(directory).name == m['decisionBaseID'] and m['decisionBaseID'].endswith('-' + p['decisionBase']), 'DB ID / version mismatch')
        for marker in ('.complete', '.p4b-complete'):
            require(self.read(directory + '/' + marker).strip() == m['decisionBaseID'], 'DB completion mismatch')
        for name in m['files']:
            require(self.path(directory + '/' + name).is_file(), 'missing DB artifact: ' + name)
        require(directory + '/manifest.json' in self.read(p['historyDocument']), 'DB history link missing')
        db = self.path(directory + '/decisions.sqlite')
        wal = Path(str(db) + '-wal')
        if wal.exists() and wal.stat().st_size:
            raise Unknown('DB has nonempty WAL; immutable metadata check deferred')
        with sqlite3.connect(db.as_uri() + '?mode=ro&immutable=1', uri=True) as connection:
            metadata = dict(connection.execute('SELECT key,value FROM metadata'))
        for key in ('ruleCommit', 'dataRuleVersion', 'ruleVersion', 'sampleID', 'decisionBaseID'):
            require(metadata.get(key) == m[key], 'SQLite metadata mismatch: ' + key)
        require(str(metadata.get('formatVersion')) == str(p['decisionBaseFormat']), 'SQLite format mismatch')

    def release_evidence(self):
        p = self.profile
        e = self.payload(p['releaseEvidence'])
        require(e.get('passed') is True, 'release verification did not pass')
        for key in ('releaseCommit', 'appVersion', 'build', 'dataRules', 'strategy', 'baseline', 'decisionBase'):
            require(e.get(key) == p[key], 'release evidence mismatch: ' + key)
        require(e.get('sourceHashesExact') is True and e.get('platform') == 'iphoneos', 'distribution source evidence missing')
        tests = self.payload(p['testEvidence'])
        require(tests.get('result') == 'Passed' and tests.get('failedTests') == 0 and tests.get('passedTests', 0) > 0, 'release tests incomplete/failed')
        require(e.get('testsPassed') == tests['passedTests'], 'test counts mismatch')
        source = self.payload(p['sourceEvidence'])['sourceHashes']
        swift = {name: value for name, value in source.items() if name.startswith('simStock3/') and name.endswith('.swift')}
        require('simStock3/technical.swift' in swift, 'release source hashes missing')
        for name, expected in swift.items():
            require(digest(self.path(name).read_bytes()) == expected, 'working source hash mismatch: ' + name)
            content = subprocess.check_output(['git', 'show', p['releaseCommit'] + ':' + name], cwd=self.root, stderr=subprocess.PIPE, timeout=30)
            require(digest(content) == expected, 'release commit source hash mismatch: ' + name)
        return '保存的發布／測試證據相符；不等於本次重跑測試或重驗簽章'

    def migration(self):
        p = self.profile
        e = self.payload(p['releaseEvidence'])
        require(e.get('technicalReplay') == p['replay']['technical'] and e.get('simulationReplay') == p['replay']['simulation'], 'replay declaration mismatch')
        if any(p['replay'].values()):
            require(e.get('persistentMigrationTestPassed') is True, 'persistent migration verification missing')
            require(isinstance(e.get('manualActions'), str) and e['manualActions'].strip(), 'manual action verification scope missing')
            return e['manualActions']
        return '不觸發資料重播'

    def local_assets(self):
        p = self.profile
        evidence = self.payload(p['releaseEvidence'])
        data = {name: self.path(p['assets'][name]).read_bytes() for name in ('manifest.plist', 'simStock3.ipa')}
        for name, content in data.items():
            require(digest(content) == evidence['hashes'][name], 'saved distribution hash mismatch: ' + name)
        asset_identity(data['manifest.plist'], data['simStock3.ipa'], p, p['urls'])
        install_link(self.read(p['pagesSnapshot']), p['urls']['manifest'])
        return '保存的 IPA／manifest／Pages 入口一致；即時發布另查'

    def history_identity(self):
        p = self.profile
        text = self.read(p['historyDocument'])
        rows = [x for x in text.splitlines() if x.startswith('| ' + p['strategy'] + '／' + p['baseline'] + ' |') and p['ruleCommit'] in x]
        require(len(rows) == 1 and p['dataRules'] in rows[0] and '| ' + p['decisionBase'] in rows[0], 'history version relationship missing/mismatched')

    def layout(self):
        p = self.profile
        require(p.get('schemaVersion') == 1, 'unsupported profile schema')
        require(p['samples'] and len(set(p['samples'])) == len(p['samples']), 'empty/duplicate samples')
        require(set(p['reports']) == set(p['samples']) == set(p['decisionBases']), 'sample coverage mismatch')
        for sample in p['samples']:
            require(set(p['reports'][sample]) == {'fixed3y', 'fullstress'}, 'both report windows required')
        require(p['ruleVersion'].split('-')[0].upper() == p['strategy'], 'strategy identifier mismatch')

    def offline(self):
        self.check('profile', self.layout)
        if self.checks[-1]['status'] != 'passed':
            return
        self.check('commits', self.commits)
        self.check('documentation-worktree', self.documentation_worktree)
        self.check('source-versions', self.source_versions)
        for sample in self.profile['samples']:
            for window, directory in self.profile['reports'][sample].items():
                self.check('report-' + sample + '-' + window, lambda s=sample, w=window, d=directory: self.report(s, w, d))
            self.check('decision-base-' + sample, lambda s=sample: self.decision_base(s, self.profile['decisionBases'][s]))
        self.check('history-identity', self.history_identity)
        self.check('release-evidence', self.release_evidence)
        self.check('migration-evidence', self.migration)
        self.check('saved-install-assets', self.local_assets)

    @staticmethod
    def download(url):
        require(url.startswith('https://'), 'only public HTTPS downloads supported')
        return subprocess.check_output(['curl', '--fail', '--silent', '--show-error', '--location', '--max-time', '120', url], stderr=subprocess.PIPE, timeout=125)

    def live_assets(self):
        p = self.profile
        e = self.payload(p['releaseEvidence'])
        manifest = self.download(p['urls']['manifest'])
        ipa = self.download(p['urls']['ipa'])
        require(digest(manifest) == e['hashes']['manifest.plist'] and digest(ipa) == e['hashes']['simStock3.ipa'], 'public assets differ from verified release')
        asset_identity(manifest, ipa, p, p['urls'])
        install_link(self.download(p['urls']['pages']).decode(), p['urls']['manifest'])

    def live_git(self):
        p = self.profile
        docs = self.git('rev-parse', self.documentation_commit + '^{commit}')
        remote = self.git('ls-remote', 'origin', 'refs/heads/main').split()
        require(remote and remote[0] == docs, 'remote main differs from documentation commit')
        result = subprocess.check_output(['gh', 'api', 'repos/' + p['repository'] + '/commits/' + docs + '/check-runs'], cwd=self.root, stderr=subprocess.PIPE, timeout=30)
        checks = json.loads(result)['check_runs']
        deploys = [x for x in checks if x.get('name') == 'deploy' and x.get('deployment', {}).get('environment') == 'github-pages' and x.get('head_sha') == docs]
        require(deploys, 'no Pages deployment check for documentation commit')
        latest = max(deploys, key=lambda x: x['id'])
        require(latest.get('status') == 'completed' and latest.get('conclusion') == 'success', 'latest Pages deployment not successful')
        return dict(documentationCommit=docs, deployment=latest.get('html_url'))

    def run(self, online=False):
        self.offline()
        if online:
            self.check('live-install-assets', self.live_assets, 'network')
            self.check('live-git-pages', self.live_git, 'network')
        else:
            for name in ('live-install-assets', 'live-git-pages'):
                self.checks.append(dict(id=name, scope='network', status='unknown', detail='未啟用 --online；保存證據不代替即時遠端'))
        statuses = [x['status'] for x in self.checks]
        overall = 'failed' if 'failed' in statuses else ('passed' if set(statuses) == {'passed'} else 'incomplete')
        offline = [x['status'] for x in self.checks if x['scope'] == 'offline']
        return dict(schemaVersion=1, status=overall, offlinePassed=bool(offline) and set(offline) == {'passed'}, checks=self.checks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--profile', default='release/closeout-profile.json')
    parser.add_argument('--documentation-commit', default='HEAD')
    parser.add_argument('--online', action='store_true', help='read public assets, origin/main and Pages deployment; never fetch/push')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    try:
        profile = json.loads((args.root / args.profile).read_text())
        report = Checker(args.root, profile, args.documentation_commit).run(args.online)
    except (OSError, ValueError, KeyError, TypeError) as error:
        report = dict(schemaVersion=1, status='incomplete', offlinePassed=False,
                      checks=[dict(id='profile-read', scope='offline', status='unknown', detail=str(error))])
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print('Release closeout:', report['status'], '| offline passed:', report['offlinePassed'])
        for item in report['checks']:
            print('[{status}] {scope}/{id}: {detail}'.format(**item))
    return {'passed': 0, 'failed': 1, 'incomplete': 2}[report['status']]


if __name__ == '__main__':
    sys.exit(main())
