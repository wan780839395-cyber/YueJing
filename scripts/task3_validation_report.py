"""Summarize all available native evidence. Never executes/retries native tools."""
import argparse
import html
import json
import os
from pathlib import Path
import re

from audit_native_case_events import audit_evidence

GROUP_STEPS = {
    'TXTCoreTests': 'core', 'ReaderDomainTests': 'domain', 'TXTBlockDecoderTests': 'block',
    'ProcessingReuseMeasurementTests': 'measurement', 'YueJingHostTests': 'host',
    'YueJingUITests': 'txt_ui', 'YueJingCanvasTests': 'canvas', 'YueJingEPUBUITests': 'epub_ui',
}
PREPARATION = ('scope', 'toolchain', 'project', 'dependencies', 'simulator', 'candidate')
FINAL_STEPS = ('test_gate', 'device_build', 'package')
DIAGNOSTIC = re.compile(r'\berror:|recorded an issue|exceeded execution time allowance|\*\* (?:TEST|BUILD) FAILED \*\*|Testing failed:', re.I)


def build_report(evidence, head, run, steps):
    audit = audit_evidence(evidence, head, run)
    problems = list(audit['errors'])
    statuses = {}
    if not isinstance(steps, dict):
        problems.append(dict(target='workflow', artifact='steps', message='Step outcomes must be an object'))
        steps = {}
    for step in (*PREPARATION, *GROUP_STEPS.values(), *FINAL_STEPS):
        record = steps.get(step, {})
        outcome = record.get('outcome', 'unknown') if isinstance(record, dict) else 'unknown'
        statuses[step] = outcome
        if outcome != 'success':
            problems.append(dict(target=step, artifact='workflow', message='Step outcome: '+str(outcome)))
    gate = None
    gate_path = evidence / 'task3/native-test-gate.json'
    try:
        gate = json.loads(gate_path.read_bytes())
        if not isinstance(gate, dict):
            raise ValueError('Gate receipt must be an object')
        if not (gate['source_commit'] == head and str(gate['run_id']) == str(run) and str(gate['run_attempt']) == '1'):
            problems.append(dict(target='test_gate', artifact=str(gate_path), message='Gate provenance mismatch'))
        gate_errors = gate.get('errors', [])
        if not isinstance(gate_errors, list):
            raise ValueError('Gate errors must be an array')
        for error in gate_errors:
            problems.append(dict(target='test_gate', artifact=str(gate_path), message=json.dumps(error, ensure_ascii=False)))
        if gate.get('passed') is not True or gate.get('native_passed') != audit['selected']:
            problems.append(dict(target='test_gate', artifact=str(gate_path), message='Exact full regression gate did not pass'))
    except (OSError, ValueError, KeyError, TypeError) as error:
        problems.append(dict(target='test_gate', artifact=str(gate_path), message=str(error)))
    for group in audit['groups']:
        group['step_outcome'] = statuses[GROUP_STEPS[group['target']]]
        if group['native_exit'] != 0:
            problems.append(dict(target=group['target'], artifact=group['log'], message='Native exit: '+str(group['native_exit'])))
        for case in group['cases']:
            if case['status'] != 'passed':
                problems.append(dict(target=group['target'], case=case['name'], artifact=group['log'],
                                     message=case['status'], issues=case['issues'], starts=case['starts'], finishes=case['finishes']))
        for entry in group['unexpected'] + group['unknown_test_lines']:
            problems.append(dict(target=group['target'], artifact=group['log'], message='Unrecognized event', event=entry))
    # Include all compiler/assertion diagnostics, including failed preparation/build logs.
    diagnostics = []
    for folder in ('task3', 'reading-ui-native', 'epub-ui-native'):
        for path in sorted((evidence / folder).glob('*.log')):
            try:
                lines = path.read_text(encoding='utf-8').splitlines()
                diagnostics.extend(dict(artifact=str(path), line=i, text=line)
                                   for i, line in enumerate(lines, 1) if DIAGNOSTIC.search(line))
            except (OSError, ValueError) as error:
                problems.append(dict(target='logs', artifact=str(path), message=str(error)))
    passed = audit['full_selected_passed'] and not problems
    return dict(source_commit=head, run_id=str(run), run_attempt='1', passed=passed,
                qualification='All discoverable issues; blocked/cancelled/unexecuted are NOT passed',
                totals=audit['totals'], selected=audit['selected'], steps=statuses, groups=audit['groups'],
                problems=problems, diagnostics=diagnostics, raw_audit_complete=audit['audit_complete'],
                gate=gate, native_commands_started=0)


def markdown(report):
    def safe(value):
        return html.escape(str(value)).replace('|', '&#124;').replace('`', '&#96;').replace('\n', '<br>')
    lines = ['# Task3 验证汇总', '', '结果：'+('全部通过' if report['passed'] else '未通过（问题见下）'),
             '', f"来源：{safe(report['source_commit'])} / run {safe(report['run_id'])} / attempt 1",
             '', '| 项目 | 步骤状态 | 通过 | 失败 | 未执行 | 跳过 | 未结束 | 歧义 | 原生退出码 |',
             '|---|---|---:|---:|---:|---:|---:|---:|---:|']
    for group in report['groups']:
        t = group['totals']
        values = [group['target'], group['step_outcome'], *[t[k] for k in
                  ('passed', 'failed', 'unexecuted', 'skipped', 'unfinished', 'ambiguous')], group['native_exit']]
        lines.append('| '+' | '.join(safe(v) for v in values)+' |')
    lines += ['', '## 全部发现的问题', '']
    for item in report['problems']:
        lines.append('- '+safe(item['target'])+': '+safe(item.get('case', ''))+' '+safe(item['message'])+' — '+safe(item.get('artifact', '')))
        for issue in item.get('issues', []):
            lines.append('  - '+safe(issue['text']))
        if 'event' in item:
            lines.append('  - '+safe(item['event']))
    if not report['problems']:
        lines.append('无。')
    lines += ['', '## 原始编译/断言诊断', '']
    for item in report['diagnostics']:
        lines.append('- '+safe(item['artifact'])+':'+str(item['line'])+' — '+safe(item['text']))
    lines += ['', '无法在准备失败、用户取消、job 超时或 runner 终止后强行运行依赖项；未执行项明确列出。',
              '本报告不触发重跑、不修复证据、不将失败或缺失结果当作通过。', '']
    return '\n'.join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--markdown', required=True, type=Path)
    args = parser.parse_args(argv)
    if args.output.resolve() == args.markdown.resolve() or args.output.exists() or args.markdown.exists():
        parser.error('Outputs must be distinct new files; existing reports are immutable')
    raw_steps = os.environ.get('VALIDATION_STEPS', '{}')
    try:
        steps = json.loads(raw_steps)
    except ValueError:
        steps = None  # Report the invalid input rather than losing all other checks.
    result = build_report(args.evidence, args.source_commit, args.run_id, steps)
    text = markdown(result)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x', encoding='utf-8') as file:
        json.dump(result, file, ensure_ascii=False, indent=2)
        file.write('\n')
    with args.markdown.open('x', encoding='utf-8') as file:
        file.write(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a', encoding='utf-8') as file:
            file.write(text)
    print(text)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
