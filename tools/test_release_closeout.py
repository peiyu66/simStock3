"""Small synthetic fixtures: no real exports, network, Simulator or strategy replay."""
import copy
import io
import json
from pathlib import Path
import plistlib
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import check_release_closeout as c


class CloseoutTests(unittest.TestCase):
    def test_git_preserves_chinese_paths(self):
        with patch.object(c.subprocess, 'check_output', return_value='doc/工作交接.md\n'.encode()) as run:
            checker = c.Checker(Path.cwd(), {})
            self.assertEqual('doc/工作交接.md', checker.git('diff', '--name-only'))
            self.assertEqual(['git', '-c', 'core.quotepath=false', 'diff', '--name-only'], run.call_args.args[0])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.profile = dict(schemaVersion=1, ruleCommit='a'*40, releaseCommit='b'*40,
            appVersion='2.1.0', build=19, bundleID='example.app', dataRules='T8/S12',
            strategy='S9', ruleVersion='s9-example', baseline='v5', decisionBase='v7',
            decisionBaseFormat=6, through='2026/01/01', moneyBaseWan=60, automaticInvestments=2,
            samples=['A'], reports={'A':{}}, decisionBases={'A':'db/A-v7'},
            periodStarts={'fixed3y':['2020/01/01','2023/01/01'], 'fullstress':['2020/01/01']},
            historyDocument='doc/history.md', documentationPaths=['doc/history.md'], releaseEvidence='evidence/release.json',
            sourceEvidence='evidence/source.json', testEvidence='evidence/tests.json',
            pagesSnapshot='evidence/page.html', replay={'technical':False,'simulation':True},
            assets={'manifest.plist':'evidence/manifest.plist','simStock3.ipa':'evidence/app.ipa'},
            urls={'ipa':'https://example.test/app.ipa','manifest':'https://example.test/manifest.plist','pages':'https://example.test/'})
        p=self.profile
        identity=dict(ruleCommit=p['ruleCommit'],dataRuleVersion=p['dataRules'],ruleVersion=p['ruleVersion'],sampleID='A',through=p['through'],moneyBaseWan=60,automaticInvestments=2)
        rows=[]
        for w,label in [('fixed3y','固定三年'),('fullstress','全期間')]:
            directory='reports/baseline-a-v5-'+w+'-example';p['reports']['A'][w]=directory
            m=dict(identity,runID=Path(directory).name,periodStarts=p['periodStarts'][w],reportFiles=['report.html','baseline.json','manifest.json','periods.csv'],browseStore='browse.store')
            self.write(directory+'/manifest.json',m);self.write(directory+'/baseline.json',dict(m,combinedScore=1.23456))
            self.write(directory+'/.complete',m['runID']);self.write(directory+'/report.html',' '.join([p['ruleCommit'],p['dataRules'],p['ruleVersion']]))
            self.write(directory+'/periods.csv','');self.write(directory+'/browse.store','fixture only')
            rows.append('| S9／v5 | '+label+' | `1.235` [report](../'+directory+'/report.html) |')
        m=dict(identity,decisionBaseID='A-v7',formatVersion=6,files=['decisions.sqlite','.complete'])
        self.write('db/A-v7/manifest.json',m)
        for name in ('.complete','.p4b-complete'):self.write('db/A-v7/'+name,'A-v7')
        with sqlite3.connect(self.root/'db/A-v7/decisions.sqlite') as db:
            db.execute('CREATE TABLE metadata(key TEXT,value TEXT)')
            db.executemany('INSERT INTO metadata VALUES(?,?)',[(k,str(v)) for k,v in m.items() if not isinstance(v,list)])
        self.write('doc/history.md','\n'.join(rows)+ '\n[DB](../db/A-v7/manifest.json)\n| S9／v5 | T8/S12 | '+p['ruleCommit']+' | v7 |')
        self.write('simStock3/technical.swift','let currentTechnicalStateVersion = 8\nlet currentSimulationStateVersion = 12\n')
        self.write('simStock3/InternalBacktestReport.swift','return "s9-example"')
        self.write('simStock3.xcodeproj/project.pbxproj','MARKETING_VERSION = 2.1.0;\nCURRENT_PROJECT_VERSION = 19;')
        manifest=plistlib.dumps({'items':[{'metadata':{'bundle-identifier':'example.app','bundle-version':'19'},'assets':[{'kind':'software-package','url':p['urls']['ipa']}]}]})
        buf=io.BytesIO()
        with zipfile.ZipFile(buf,'w') as z:
            z.writestr('Payload/Test.app/Info.plist',plistlib.dumps(dict(CFBundleIdentifier='example.app',CFBundleVersion='19',CFBundleShortVersionString='2.1.0',CFBundleSupportedPlatforms=['iPhoneOS'])))
        self.write(p['assets']['manifest.plist'],manifest);self.write(p['assets']['simStock3.ipa'],buf.getvalue())
        self.write(p['pagesSnapshot'],'<a href="itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fexample.test%2Fmanifest.plist">Install</a>')
        self.write(p['releaseEvidence'],dict(passed=True,releaseCommit=p['releaseCommit'],appVersion=p['appVersion'],build=19,dataRules=p['dataRules'],strategy='S9',baseline='v5',decisionBase='v7',sourceHashesExact=True,platform='iphoneos',testsPassed=3,technicalReplay=False,simulationReplay=True,persistentMigrationTestPassed=True,manualActions='Synthetic fixture; retained/redundant/invalid checked',hashes={'manifest.plist':c.digest(manifest),'simStock3.ipa':c.digest(buf.getvalue())}))
        self.write(p['testEvidence'],dict(result='Passed',failedTests=0,passedTests=3))
        self.write(p['sourceEvidence'],dict(sourceHashes={'simStock3/technical.swift':c.digest((self.root/'simStock3/technical.swift').read_bytes())}))
        self.checker=c.Checker(self.root,p)
        self.checker.git=self.git
        self.subprocess_patch=patch.object(c.subprocess,'check_output',side_effect=self.command).start()
        self.addCleanup(patch.stopall)

    def write(self,name,data):
        path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True)
        if isinstance(data,dict):data=json.dumps(data)
        if isinstance(data,bytes):path.write_bytes(data)
        else:path.write_text(data)

    def change(self,name,key,value):
        data=json.loads((self.root/name).read_text());data[key]=value;self.write(name,data)

    def command(self,args,**kwargs):
        if args[:2]==['git','show']:return (self.root/args[2].split(':',1)[1]).read_bytes()
        raise OSError('network unavailable in fixture')

    def git(self,*args):
        if args[0]=='rev-parse':return 'c'*40 if args[-1].startswith('HEAD') else args[-1].split('^')[0]
        if args[0]=='merge-base':return args[1]
        if args[0]=='show':return (self.root/args[1].split(':',1)[1]).read_text()
        if args[0] in ('diff','ls-files'):return ''
        raise OSError('network unavailable')

    def result(self):return self.checker.run()
    def fails(self,id):
        r=self.result();self.assertEqual('failed',r['status']);self.assertIn(id,[x['id'] for x in r['checks'] if x['status']=='failed'])

    def test_good_offline_is_not_network_pass(self):
        r=self.result();self.assertTrue(r['offlinePassed']);self.assertEqual('incomplete',r['status']);self.assertEqual(2,len([x for x in r['checks'] if x['status']=='unknown']))
    def test_missing_evidence_is_unknown(self):
        (self.root/self.profile['releaseEvidence']).unlink();r=self.result();self.assertFalse(r['offlinePassed']);self.assertEqual('incomplete',r['status'])
    def test_short_commit_rejected(self):self.profile['ruleCommit']='a'*7;self.fails('commits')
    def test_nonancestor_rejected(self):
        self.checker.git=lambda *a:'d'*40 if a[0]=='merge-base' else self.git(*a);self.fails('commits')
    def test_unreleased_app_commit(self):
        self.checker.git=lambda *a:'simStock3/technical.swift' if a[:2]==('diff','--name-only') else self.git(*a);self.fails('commits')
    def test_wrong_source_version(self):self.write('simStock3/technical.swift','let currentTechnicalStateVersion = 8\nlet currentSimulationStateVersion = 13');self.fails('source-versions')
    def test_uncommitted_document_is_not_deployed(self):
        self.checker.git=lambda *a:'doc/history.md' if a[:2]==('diff','--name-only') else self.git(*a)
        r=self.result();self.assertEqual('incomplete',r['status']);self.assertFalse(r['offlinePassed'])
        self.assertEqual('unknown',next(x['status'] for x in r['checks'] if x['id']=='documentation-worktree'))
    def test_malformed_source_fails_without_crash(self):self.write('simStock3/technical.swift','bad');self.fails('source-versions')
    def test_missing_sample_window(self):del self.profile['reports']['A']['fullstress'];self.fails('profile')
    def test_wrong_manifest_commit(self):self.change(self.profile['reports']['A']['fixed3y']+'/manifest.json','ruleCommit','d'*40);self.fails('report-A-fixed3y')
    def test_wrong_report_marker(self):self.write(self.profile['reports']['A']['fixed3y']+'/.complete','old-run');self.fails('report-A-fixed3y')
    def test_wrong_periods(self):self.change(self.profile['reports']['A']['fullstress']+'/baseline.json','periodStarts',['wrong']);self.fails('report-A-fullstress')
    def test_history_index_missing_even_if_report_link_elsewhere(self):
        path=self.root/'doc/history.md';path.write_text(path.read_text().replace('| S9／v5 | 固定三年 |','not an index row'));self.fails('report-A-fixed3y')
    def test_history_score_mismatch(self):
        path=self.root/'doc/history.md';path.write_text(path.read_text().replace('1.235','9.999'));self.fails('report-A-fixed3y')
    def test_db_format_mismatch(self):self.change('db/A-v7/manifest.json','formatVersion',99);self.fails('decision-base-A')
    def test_db_metadata_mismatch(self):
        with sqlite3.connect(self.root/'db/A-v7/decisions.sqlite') as db:db.execute("UPDATE metadata SET value='old' WHERE key='ruleCommit'")
        self.fails('decision-base-A')
    def test_nonempty_wal_unknown(self):
        self.write('db/A-v7/decisions.sqlite-wal',b'pending');r=self.result();self.assertEqual('unknown',next(x['status'] for x in r['checks'] if x['id']=='decision-base-A'))
    def test_migration_proof_missing(self):self.change(self.profile['releaseEvidence'],'persistentMigrationTestPassed',False);self.fails('migration-evidence')
    def test_test_failures_rejected(self):self.change(self.profile['testEvidence'],'failedTests',1);self.fails('release-evidence')
    def test_old_manifest_even_with_matching_recorded_hash(self):
        path=self.profile['assets']['manifest.plist'];m=plistlib.loads((self.root/path).read_bytes());m['items'][0]['metadata']['bundle-version']='18';data=plistlib.dumps(m);self.write(path,data)
        e=json.loads((self.root/self.profile['releaseEvidence']).read_text());e['hashes']['manifest.plist']=c.digest(data);self.write(self.profile['releaseEvidence'],e);self.fails('saved-install-assets')
    def test_wrong_pages_target(self):self.write(self.profile['pagesSnapshot'],'<a href="https://example.test/">Install</a>');self.fails('saved-install-assets')
    def test_network_failure_is_blocked(self):
        r=self.checker.run(True);self.assertEqual('incomplete',r['status']);self.assertTrue(all(x['status']=='blocked' for x in r['checks'] if x['scope']=='network'))
    def test_profile_path_escape(self):
        self.profile['historyDocument']='../outside';self.fails('history-identity')
    def test_read_only_leaves_fixture_bytes_unchanged(self):
        before={str(p):c.digest(p.read_bytes()) for p in self.root.rglob('*') if p.is_file()};self.result();after={str(p):c.digest(p.read_bytes()) for p in self.root.rglob('*') if p.is_file()};self.assertEqual(before,after)


if __name__=='__main__':unittest.main()
