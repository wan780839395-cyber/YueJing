"""Offline multi-failure regressions. Synthetic files only; native tools forbidden."""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import audit_native_case_events as audit
import task3_test_inventory as inventory
import task3_validation_report as reporting
import validate_task3 as gate

ROOT = Path(__file__).resolve().parents[1]
HEAD, RUN = 'synthetic-sha', 'synthetic-run'


def put(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding='utf-8')


def group_folder(root, target):
    return root / ('epub-ui-native' if target == 'YueJingEPUBUITests' else
                   'reading-ui-native' if target in ('YueJingHostTests', 'YueJingUITests') else 'task3')


def fake_evidence(root, failures=None):
    failures = failures or {}
    for target in inventory.COUNTS:
        folder = group_folder(root, target)
        folder.mkdir(parents=True, exist_ok=True)
        names = inventory.expected_names(target)
        failed = set(failures.get(target, []))
        lines = []
        for name in names:
            status = 'failed' if name in failed else 'passed'
            if target in ('YueJingUITests', 'YueJingEPUBUITests'):
                cls = 'EPUBFlowUITests' if target == 'YueJingEPUBUITests' else 'ReadingFlowUITests'
                prefix = f"Test Case '-[{target}.{cls} {name}]'"
                lines += [prefix+' started.', prefix+f' {status} (0.1 seconds).']
            else:
                lines.append(f'Test {name}() started.')
                if name in failed:
                    lines.append(f'✘ Test {name}() recorded an issue at Synthetic.swift:10:1: synthetic assertion')
                lines.append(f'Test {name}() {status} after 0.1 seconds.')
        data = ('\n'.join(lines)+'\n').encode()
        (folder / (target+'.log')).write_bytes(data)
        code = 65 if failed else 0
        (folder / (target+'-exit-code.txt')).write_text(str(code), encoding='utf-8')
        provenance = dict(source_commit=HEAD, run_id=RUN, run_attempt='1')
        put(folder / (target+'-counts.json'), dict(provenance, log_sha256=audit.digest(data), passed=[n for n in names if n not in failed]))
        if target in ('YueJingHostTests', 'YueJingUITests', 'YueJingEPUBUITests'):
            put(folder / (target+'-selection.json'), provenance)
            put(folder / (target+'-execution.json'), dict(provenance, native_exit=code))
    put(root / 'task3/native-test-gate.json', dict(source_commit=HEAD, run_id=RUN, run_attempt='1',
        passed=not failures, native_passed=inventory.TOTAL-sum(map(len, failures.values())), errors=[]))


def step_outcomes():
    return {n: dict(outcome='success') for n in (*reporting.PREPARATION, *reporting.GROUP_STEPS.values(), *reporting.FINAL_STEPS)}


class AggregationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='validation-aggregate-', dir=os.environ.get('PI_SCRATCH_DIR'))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.no_native = patch('subprocess.Popen', side_effect=AssertionError('No native/other process allowed'))
        self.no_native.start()
        self.addCleanup(self.no_native.stop)

    def test_full_inventory_positive_and_no_native_process(self):
        fake_evidence(self.root)
        result = reporting.build_report(self.root, HEAD, RUN, step_outcomes())
        self.assertTrue(result['passed'])
        self.assertEqual(result['totals']['passed'], 214)
        self.assertEqual(result['native_commands_started'], 0)

    def test_multiple_groups_and_multiple_cases_all_reported(self):
        domain = inventory.expected_names('ReaderDomainTests')[:2]
        epub = inventory.expected_names('YueJingEPUBUITests')[-1:]
        fake_evidence(self.root, {'ReaderDomainTests': domain, 'YueJingEPUBUITests': epub})
        steps = step_outcomes()
        for key in ('domain', 'epub_ui', 'test_gate'):
            steps[key]['outcome'] = 'failure'
        result = reporting.build_report(self.root, HEAD, RUN, steps)
        self.assertFalse(result['passed'])
        self.assertEqual(result['totals']['failed'], 3)
        self.assertEqual({p['case'] for p in result['problems'] if p.get('message') == 'failed'}, set(domain+epub))
        self.assertEqual(len(result['groups']), 8)
        self.assertEqual(next(g for g in result['groups'] if g['target']=='YueJingCanvasTests')['totals']['passed'], 3)
        self.assertEqual(len(result['diagnostics']), 2)
        text = reporting.markdown(result)
        self.assertTrue(all(n in text for n in domain+epub))

    def test_bad_utf8_json_exit_and_provenance_do_not_abort_later_groups(self):
        fake_evidence(self.root)
        (self.root/'task3/TXTCoreTests.log').write_bytes(b'\xff')
        (self.root/'task3/ReaderDomainTests-counts.json').write_text('{', encoding='utf-8')
        (self.root/'task3/TXTBlockDecoderTests-exit-code.txt').write_text('not-an-integer', encoding='utf-8')
        host = self.root/'reading-ui-native/YueJingHostTests-selection.json'
        put(host, dict(source_commit='wrong', run_id=RUN, run_attempt='1'))
        result = audit.audit_evidence(self.root, HEAD, RUN)
        self.assertEqual({e['target'] for e in result['errors']}, {'TXTCoreTests','ReaderDomainTests','TXTBlockDecoderTests','YueJingHostTests'})
        self.assertEqual(result['groups'][-1]['totals']['passed'], 3)
        self.assertFalse(result['full_selected_passed'])

    def test_missing_preparation_marks_every_group_unexecuted(self):
        steps = {n:dict(outcome='skipped') for n in step_outcomes()}
        steps['dependencies']['outcome'] = 'failure'
        result = reporting.build_report(self.root, HEAD, RUN, steps)
        self.assertFalse(result['passed'])
        self.assertEqual(result['totals']['unexecuted'], 214)
        self.assertEqual(len(result['groups']), 8)
        self.assertTrue(any(p['target']=='dependencies' for p in result['problems']))

    def test_issue_is_not_unknown_but_never_turns_green(self):
        text = 'Test alpha() started.\n✘ Test alpha() recorded an issue at A.swift:1:1: bad\nTest alpha() failed after 1 seconds.\n'
        result = audit.parse_events(text.encode(), ['alpha'])
        self.assertTrue(result['parser_complete'])
        self.assertEqual(result['totals']['failed'], 1)
        self.assertEqual(len(result['cases'][0]['issues']), 1)
        false_green = audit.parse_events(text.replace('failed after','passed after').encode(), ['alpha'])
        self.assertFalse(false_green['parser_complete'])
        self.assertEqual(false_green['totals']['ambiguous'], 1)
        self.assertFalse(audit.parse_events(text.encode(), ['other'])['parser_complete'])

    def test_report_command_writes_both_outputs_before_failure_exit(self):
        failures = {t:inventory.expected_names(t)[:1] for t in ('TXTCoreTests','ReaderDomainTests','YueJingEPUBUITests')}
        fake_evidence(self.root, failures)
        output, md = self.root/'result.json', self.root/'result.md'
        args = ['--evidence',str(self.root),'--source-commit',HEAD,'--run-id',RUN,'--output',str(output),'--markdown',str(md)]
        with patch.dict(os.environ, {'VALIDATION_STEPS':json.dumps(step_outcomes()), 'GITHUB_STEP_SUMMARY':''}), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(reporting.main(args), 1)
        data = json.loads(output.read_bytes())
        self.assertEqual(data['totals']['failed'], 3)
        self.assertTrue(all(n[0] in md.read_text(encoding='utf-8') for n in failures.values()))

    def test_strict_gate_collects_multiple_group_errors(self):
        from check_task3_validation import synthetic_fixture
        env = dict(GITHUB_SHA=HEAD,GITHUB_RUN_ID=RUN,GITHUB_RUN_ATTEMPT='1',GITHUB_EVENT_NAME='workflow_dispatch')
        with patch.object(gate,'ROOT',self.root), patch.object(gate,'OUT',self.root/'task3'), patch.dict(os.environ,env):
            synthetic_fixture(self.root)
            self.assertTrue(gate.collect_all_test_evidence()['passed'])
            (self.root/'task3/TXTCoreTests-counts.json').write_text('{',encoding='utf-8')
            (self.root/'task3/ReaderDomainTests-counts.json').write_text('{',encoding='utf-8')
            (self.root/'artifacts/epub-ui-native/YueJingEPUBUITests-settings.json').write_text('{',encoding='utf-8')
            host_path = self.root/'artifacts/reading-ui-native/YueJingHostTests-settings.json'
            host = json.loads(host_path.read_bytes())
            host['fixture_environment'] = ['invalid UUID type']
            put(host_path, host)
            result = gate.collect_all_test_evidence()
            self.assertFalse(result['passed'])
            self.assertIsNone(result['unexecuted'])
            self.assertGreater(result['unverified'], 0)
            encoded = json.dumps(result['errors'])
            for target in ('TXTCoreTests','ReaderDomainTests','YueJingHostTests','YueJingEPUBUITests'):
                self.assertIn(target,encoded)
            with self.assertRaises(ValueError):
                gate.all_test_evidence()
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ValueError):
                gate.write_all_test_evidence()
            self.assertFalse(json.loads((self.root/'task3/native-test-gate.json').read_bytes())['passed'])

    def test_actual_workflow_conditions_continue_after_two_failures(self):
        workflow = (ROOT/'.github/workflows/task3-validate.yml').read_text(encoding='utf-8')
        blocks = re.split(r'^      - name: ',workflow,flags=re.M)[1:]
        by_id = {re.search(r'^        id: (\w+)$',b,re.M)[1]:b for b in blocks if re.search(r'^        id: (\w+)$',b,re.M)}
        outcomes = step_outcomes()
        outcomes['host_preflight'] = dict(outcome='skipped')
        outcomes['domain']['outcome'] = outcomes['host']['outcome'] = 'failure'
        def condition(key, cancelled=False, scope='full'):
            expression = re.search(r'^        if: \$\{\{ (.+) \}\}$',by_id[key],re.M)[1]
            expression = expression.replace('&&',' and ').replace('||',' or ')
            expression = re.sub(r'!(?!=)', 'not ',expression)
            return eval(expression, {'__builtins__':{}}, dict(
                steps=SimpleNamespace(**{k:SimpleNamespace(**v) for k,v in outcomes.items()}),
                inputs=SimpleNamespace(validation_scope=scope), cancelled=lambda:cancelled,
                success=lambda:all(v['outcome'] not in ('failure','cancelled') for v in outcomes.values()), always=lambda:True))
        for key in reporting.GROUP_STEPS.values():
            self.assertTrue(condition(key), key)
            self.assertFalse(condition(key,cancelled=True), key)
            self.assertNotIn('continue-on-error',by_id[key])
        self.assertTrue(condition('test_gate'))
        self.assertTrue(condition('validation_summary'))
        self.assertFalse(condition('device_build'))
        self.assertFalse(condition('package'))
        outcomes['candidate']['outcome']='failure'
        for key in reporting.GROUP_STEPS.values():
            self.assertFalse(condition(key), key)
        self.assertTrue(condition('validation_summary'))
        self.assertEqual(re.findall(r'^\s+timeout-minutes: (\d+)\s*$',workflow,re.M),['60','12','23','10','30','45'])
        self.assertEqual(workflow.count('id: validation_summary'),1)
        self.assertEqual(workflow.count('python3 -B scripts/task3_validation_report.py'),1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
