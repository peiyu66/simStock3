"""Runner-only fixtures; no App, Simulator, network or strategy execution."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('run-contract-tests.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ContractRunnerTests(unittest.TestCase):
    selected = ['simStock3Tests/ExampleTests/testOne', 'simStock3Tests/ExampleTests/testTwo']

    def payload(self, statuses=('Passed', 'Passed')):
        return {'testNodes': [{'nodeType': 'Test Suite', 'name': 'ExampleTests', 'children': [
            {'nodeType': 'Test Case', 'name': 'test' + name + '()',
             'nodeIdentifier': 'ExampleTests/test' + name + '()', 'result': status}
            for name, status in zip(['One', 'Two'], statuses)]}]}

    def test_exact_selection_passes(self):
        self.assertEqual(r.test_results(self.payload(), self.selected)['status'], 'passed')

    def test_zero_tests_does_not_pass(self):
        result = r.test_results({'testNodes': []}, self.selected)
        self.assertEqual(result['counts'], {'not-run': 2})
        self.assertEqual(result['status'], 'failed')

    def test_skipped_unknown_expected_failure_and_failed_do_not_pass(self):
        for status in ['Skipped', 'unknown', 'Expected Failure', 'Failed']:
            with self.subTest(status=status):
                result = r.test_results(self.payload(['Passed', status]), self.selected)
                self.assertEqual(result['status'], 'failed')

    def test_missing_case_does_not_pass(self):
        self.assertEqual(r.test_results(self.payload(['Passed']), self.selected)['status'], 'failed')

    def test_extra_case_does_not_pass(self):
        self.assertEqual(r.test_results(self.payload(), self.selected[:1])['status'], 'failed')

    def test_duplicate_case_does_not_pass(self):
        data = self.payload()
        data['testNodes'] *= 2
        self.assertEqual(r.test_results(data, self.selected)['status'], 'failed')

    def test_renamed_test_is_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'simStock3Tests').mkdir()
            (root / 'simStock3Tests/ExampleTests.swift').write_text('func testOne() {}')
            selection = root / 'selection.json'
            selection.write_text(json.dumps(dict(schemaVersion=1, target='simStock3Tests',
                suites={'ExampleTests': ['testRenamed']})))
            with self.assertRaisesRegex(ValueError, 'missing'):
                r.selected_tests(root, selection)

    def test_normal_and_research_simulators_are_rejected(self):
        for name in ['simStock3 iPad 10.86 inch', 'simStock3 回測']:
            with self.assertRaises(ValueError):
                r.isolated_device({'devices': {'iOS-26-5': [dict(udid='ID', name=name, isAvailable=True)]}}, 'ID')
        self.assertEqual(r.isolated_device({'devices': {'iOS-26-5': [dict(udid='ID',
            name=r.DEVICE_PREFIX + 'fixture', isAvailable=True)]}}, 'ID')['udid'], 'ID')

    def test_timeout_stops_owned_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(TimeoutError):
                r.Runner(Path(tmp), 0.3, 10).run('fixture', [sys.executable, '-c', 'import time; time.sleep(10)'])

    def test_checked_in_selection_names_exist(self):
        self.assertGreater(len(r.selected_tests()), 0)


if __name__ == '__main__':
    unittest.main()
