"""Read-only native-event audit. Derived starts retain original line spans; never rewrites logs."""
import argparse
import hashlib
import json
from pathlib import Path
import re

EVENT = re.compile(r"\bTest (\w+)\(\) (started|passed|failed|skipped)\b")
ISSUE = re.compile(r"^(?:✘ )?Test (\w+)\(\) recorded an issue at (.+)$")
UI_EVENT = re.compile(r"Test Case '-\[(?:\w+\.)?ReadingFlowUITests (test\w+)\]' (started|passed|failed|skipped)\b")
EPUB_UI_EVENT = re.compile(r"Test Case '-\[(?:\w+\.)?EPUBFlowUITests (test\w+)\]' (started|passed|failed|skipped)\b")
# Only the observed UIKit warning is admissible, and only inside a START record.
BROKEN_START = re.compile(
    r"^(?:◇ )?Test (?P<prefix>[A-Za-z_]\w*)"
    r"20\d\d-\d\d-\d\d \d\d:\d\d:\d\d\.\d{6}\+\d{4} "
    r"YueJing\[\d+:\d+\] Unbalanced calls to begin/end appearance transitions for "
    r"<YueJing\.ReaderViewController: 0x[0-9a-fA-F]+>\.$")
START_TAIL = re.compile(r"^(?P<suffix>\w+)\(\) started\.$")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def parse_events(raw, names, ui=False, ui_class="ReadingFlowUITests"):
    if len(names) != len(set(names)):
        raise ValueError('Nonunique expected identities')
    text = raw.decode('utf-8')
    original = text.splitlines(keepends=True)
    lines = text.splitlines()
    events = {n: dict(starts=[], finishes=[], skips=[], issues=[]) for n in names}
    unexpected, unknown, derived = [], [], []
    consumed = set()
    if ui_class not in ("ReadingFlowUITests", "EPUBFlowUITests"):
        raise ValueError('Unapproved UI class')
    pattern = (EPUB_UI_EVENT if ui_class == "EPUBFlowUITests" else UI_EVENT) if ui else EVENT
    for i, line in enumerate(lines):
        if i in consumed:
            continue
        records = list(pattern.finditer(line))
        if records:
            for match in records:
                name, event = match.groups()
                row = dict(line=i+1, kind='original-complete-line', text=line)
                if name not in events:
                    unexpected.append(dict(name=name, event=event, **row))
                elif event == 'started':
                    events[name]['starts'].append(row)
                elif event == 'skipped':
                    events[name]['skips'].append(row)
                else:
                    events[name]['finishes'].append(dict(status=event, **row))
            if ui and 'Test Case' in pattern.sub('', line):
                unknown.append(dict(line=i+1, text=line))
            continue
        if ui and re.match(r'^(?:\d{4}-\d\d-\d\dT\S+ )?Test Case\b', line):
            unknown.append(dict(line=i+1, text=line))
        if not ui:
            issue = ISSUE.fullmatch(line)
            if issue:
                name, detail = issue.groups()
                row = dict(line=i+1, text=line, detail=detail)
                if name in events:
                    events[name]['issues'].append(row)
                else:
                    unexpected.append(dict(name=name, event='issue', **row))
                continue
            before = BROKEN_START.fullmatch(line)
            after = START_TAIL.fullmatch(lines[i+1]) if i+1 < len(lines) else None
            if before and after:
                name = before['prefix'] + after['suffix']
                if name in events:
                    span = ''.join(original[i:i+2]).encode('utf-8')
                    row = dict(line=i+1, end_line=i+2, kind='derived-start-known-UIKit-interleave',
                               raw_span_sha256=digest(span), warning_retained=True)
                    events[name]['starts'].append(row)
                    derived.append(dict(name=name, **row))
                    consumed.add(i+1)
                    continue
            if line == 'Test session results, code coverage, and logs:':
                continue
            if re.match(r'^(?:◇ |✔ |✘ )?Test (?!run\b|Suite\b)', line):
                unknown.append(dict(line=i+1, text=line))
    cases = []
    for name, item in events.items():
        starts, ends, skips = item['starts'], item['finishes'], item['skips']
        if skips:
            status = 'skipped'
        elif len(starts) == len(ends) == 1 and starts[0]['line'] < ends[0]['line']:
            status = ends[0]['status']
            if item['issues'] and status != 'failed':
                status = 'ambiguous'  # An issue can never be hidden by a green finish.
        elif not starts and not ends and not item['issues']:
            status = 'unexecuted'
        elif len(starts) == 1 and not ends:
            status = 'unfinished'
        else:
            status = 'ambiguous'
        cases.append(dict(name=name, status=status, **item))
    totals = {s: sum(c['status'] == s for c in cases) for s in
              ('passed', 'failed', 'skipped', 'unexecuted', 'unfinished', 'ambiguous')}
    return dict(raw_sha256=digest(raw), expected=len(names), cases=cases, totals=totals,
                unexpected=unexpected, unknown_test_lines=unknown, derived_starts=derived,
                parser_complete=not unexpected and not unknown and not totals['ambiguous'] and not totals['unfinished'])


def self_check():
    names = ['alphaCase', 'betaCase']
    warning = ('2026-11-03 01:03:26.162225+0000 YueJing[13720:50426] Unbalanced calls to begin/end '
               'appearance transitions for <YueJing.ReaderViewController: 0x1049b1a00>.')
    good = ('◇ Test alphaCase() started.\n✔ Test alphaCase() passed after 0.1 seconds.\n'
            '◇ Test betaCase() started.\n✔ Test betaCase() passed after 0.1 seconds.\n')
    split = good.replace('◇ Test betaCase() started.', '◇ Test beta'+warning+'\nCase() started.')
    def accepted(text):
        result = parse_events(text.encode(), names)
        return result['parser_complete'] and result['totals']['passed'] == 2
    assert accepted(good) and accepted(split)
    assert accepted(good + 'Test session results, code coverage, and logs:\n')
    assert len(parse_events(split.encode(), names)['derived_starts']) == 1
    variants = {
        'unknown-warning': split.replace('Unbalanced calls', 'Unrecognized calls'),
        'unknown-class': split.replace('ReaderViewController:', 'OtherController:'),
        'split-pass-not-reconstructed': good.replace('✔ Test betaCase() passed after 0.1 seconds.', '✔ Test beta'+warning+'\nCase() passed after 0.1 seconds.'),
        'unknown-name': good.replace('betaCase', 'gammaCase'),
        'duplicate-start': good + '◇ Test betaCase() started.\n',
        'duplicate-end': good + '✔ Test betaCase() passed after 0.1 seconds.\n',
        'missing-start': good.replace('◇ Test betaCase() started.\n', ''),
        'missing-end': good.replace('✔ Test betaCase() passed after 0.1 seconds.\n', ''),
        'failure-not-passed': good.replace('betaCase() passed', 'betaCase() failed'),
        'skip-not-passed': good + '◇ Test betaCase() skipped.\n',
        'multi-line-gap': split.replace('\nCase() started.', '\nintervening\nCase() started.'),
        'wrong-tail': split.replace('Case() started.', 'Case() finished.'),
        'unknown-report-heading': good + 'Test session results, unknown:\n',
    }
    for label, text in variants.items():
        assert not accepted(text), 'Unsafe audit accepted: '+label
    failed = parse_events(good.replace('betaCase() passed', 'betaCase() failed').encode(), names)
    assert failed['parser_complete'] and failed['totals']['failed'] == 1
    ui_good = ("Test Case '-[ReadingFlowUITests testAlpha]' started.\n"
               "Test Case '-[ReadingFlowUITests testAlpha]' passed (0.1 seconds).\n")
    assert parse_events(ui_good.encode(), ['testAlpha'], ui=True)['parser_complete']
    assert parse_events((ui_good+'A test identifier can be used to specify a Test Case or a Test Suite. All\n').encode(), ['testAlpha'], ui=True)['parser_complete']
    ui_variants = {
        'ui-unknown-class': ui_good + "Test Case '-[OtherTests testOther]' started.\n",
        'ui-unknown-status': ui_good + "Test Case '-[ReadingFlowUITests testAlpha]' interrupted.\n",
        'ui-malformed-event': ui_good + "Test Case incomplete started.\n",
        'ui-extra-same-line': ui_good.replace('started.', "started. Test Case malformed"),
        'ui-unknown-method': ui_good + "Test Case '-[ReadingFlowUITests testOther]' started.\n",
    }
    for label, text in ui_variants.items():
        assert not parse_events(text.encode(), ['testAlpha'], ui=True)['parser_complete'], label
    epub_good = ui_good.replace('ReadingFlowUITests', 'EPUBFlowUITests')
    parsed = parse_events(epub_good.encode(), ['testAlpha'], ui=True, ui_class='EPUBFlowUITests')
    assert parsed['parser_complete'] and parsed['totals']['passed'] == 1
    for text in ui_variants.values():
        variant = text.replace('ReadingFlowUITests', 'EPUBFlowUITests')
        assert not parse_events(variant.encode(), ['testAlpha'], ui=True, ui_class='EPUBFlowUITests')['parser_complete']
    assert not parse_events(ui_good.encode(), ['testAlpha'], ui=True, ui_class='EPUBFlowUITests')['parser_complete']
    assert not parse_events(epub_good.encode(), ['testAlpha'], ui=True)['parser_complete']
    return dict(passed=True, positive_controls=8, negative_controls=len(variants)+2*len(ui_variants)+2, native_executions=0)


def audit_evidence(evidence, head, run):
    """Inspect every group/receipt independently; errors deny acceptance, not inspection."""
    import task3_test_inventory as inventory
    errors = []
    try:
        reviewed = inventory.validate_source()
    except (OSError, ValueError, KeyError, TypeError) as error:
        reviewed = dict(selected=inventory.TOTAL)
        errors.append(dict(target='inventory', artifact='source', message=str(error)))
    groups = []
    for target in inventory.COUNTS:
        folder = evidence / ('epub-ui-native' if target == 'YueJingEPUBUITests' else
                             'reading-ui-native' if target in ('YueJingHostTests', 'YueJingUITests') else 'task3')
        group_errors = []
        def problem(path, error):
            group_errors.append(dict(target=target, artifact=str(path), message=str(error)))
        names = inventory.expected_names(target)
        def parse(raw):
            return parse_events(raw, names, target in ('YueJingUITests', 'YueJingEPUBUITests'),
                                'EPUBFlowUITests' if target == 'YueJingEPUBUITests' else 'ReadingFlowUITests')
        log = folder / (target+'.log')
        raw = b''
        try:
            raw = log.read_bytes()
            parsed = parse(raw)
        except (OSError, ValueError) as error:
            problem(log, error)
            parsed = parse(b'')
            parsed['raw_sha256'] = digest(raw)
            parsed['parser_complete'] = False
        native_exit_path = folder / (target+'-exit-code.txt')
        native_exit = None
        try:
            native_exit = int(native_exit_path.read_text().strip())
        except (OSError, ValueError) as error:
            problem(native_exit_path, error)
        required = ('counts', 'execution', 'selection') if target in ('YueJingHostTests', 'YueJingUITests', 'YueJingEPUBUITests') else ('counts',)
        for suffix in ('counts', 'execution', 'selection'):
            p = folder / (target+'-'+suffix+'.json')
            if not p.exists() and suffix not in required:
                continue
            try:
                receipt = json.loads(p.read_bytes())
                if not isinstance(receipt, dict):
                    raise ValueError('Receipt must be an object')
                if not (receipt['source_commit'] == head and str(receipt['run_id']) == str(run) and str(receipt['run_attempt']) == '1'):
                    problem(p, 'Receipt provenance mismatch')
                if suffix == 'counts':
                    passed = {c['name'] for c in parsed['cases'] if c['status'] == 'passed'}
                    if receipt['log_sha256'] != digest(raw) or set(receipt['passed']) != passed:
                        problem(p, 'Count receipt/raw identities differ')
                if suffix == 'execution' and receipt['native_exit'] != native_exit:
                    problem(p, 'Native exit receipt differs')
            except (OSError, ValueError, KeyError, TypeError) as error:
                problem(p, error)
        groups.append(dict(target=target, log=str(log) if log.exists() else None, native_exit=native_exit,
                           errors=group_errors, **parsed))
        errors.extend(group_errors)
    totals = {s: sum(g['totals'][s] for g in groups) for s in groups[0]['totals']}
    complete = not errors and all(g['parser_complete'] for g in groups)
    full_pass = complete and totals['passed'] == inventory.TOTAL and all(not v for k,v in totals.items() if k != 'passed') and all(g['native_exit'] == 0 for g in groups)
    return dict(source_commit=head, run_id=str(run), attempt=1, selected=reviewed['selected'], groups=groups,
                totals=totals, errors=errors, audit_complete=complete, full_selected_passed=full_pass,
                full146_passed=full_pass and inventory.TOTAL == 146,
                status='AUDIT_COMPLETED' if complete else 'AUDIT_INCOMPLETE',
                native_validation='passed' if full_pass else 'not passed', raw_logs_modified=False,
                qualification='Derived starts are explicitly sourced; they are not original intact event lines')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-check', action='store_true')
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--source-commit')
    parser.add_argument('--run-id')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.self_check:
        print(json.dumps(self_check(), indent=2))
    if args.evidence:
        if not args.source_commit or not args.run_id or not args.output:
            parser.error('Evidence audit requires source commit, run ID and exclusive output')
        result = audit_evidence(args.evidence, args.source_commit, args.run_id)
        with args.output.open('x', encoding='utf-8') as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
            f.write('\n')
        print(json.dumps({k:result[k] for k in ('status','audit_complete','totals','full_selected_passed')}, indent=2))


if __name__ == '__main__':
    main()
