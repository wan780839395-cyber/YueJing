"""Offline DISPLAY_ONLY failure details. No execution, qualification or source lookup.

Within a log the first diagnostic wins; explicit log order precedes xcresult
fallbacks and generic receipts. Cross-file order is not a claimed timeline.
XCTAssertEqual operands are preserved, never guessed to be expected/actual.
"""
import hashlib
import html
import json
from pathlib import Path
import re
from urllib.parse import unquote

MODE = 'DISPLAY_ONLY'
MAX_BYTES = 32 * 1024 * 1024
SOURCE = re.compile(r'(?P<file>(?:[A-Za-z]:)?[^\s]+\.(?:swift|m|mm|c|cc|cpp|h)):(?P<line>\d+)(?::(?P<column>\d+))?:')
CASE = re.compile(r'-\[([^\]]+)\]')
ASSERTION = re.compile(r'XCTAssert\w* failed|XCTFail\b|Expectation failed:|recorded an issue at|Assertion Failure', re.I)
TIMEOUT = re.compile(r'exceeded execution time allowance', re.I)
QUERY = re.compile(r'(?:xcodebuild|xcrun|swift|xcodegen).*?(?:-version|--version|-showBuildSettings|-showdestinations|simctl.*?list)', re.I)
EQUAL = re.compile(r'\("(.*?)"\) is not equal to \("(.*?)"\)')
EXPLICIT_VALUES = re.compile(r'\bexpected\s*[:=]\s*(.*?)\s*[,;]\s*actual\s*[:=]\s*(.*)', re.I)


def _source(text):
    match = SOURCE.search(text)
    if not match:
        return {'file': 'unknown', 'line': 'unknown', 'column': 'unknown'}
    return {'file': match['file'], 'line': int(match['line']),
            'column': int(match['column']) if match['column'] else 'unknown'}


def _kind(text, *, test_failure=False):
    if TIMEOUT.search(text):
        return 'xctest_case_timeout', 'test_case'
    if re.search(r'timed out after|TimeoutExpired', text, re.I) and QUERY.search(text):
        return 'tool_query_timeout', 'tool_query'
    if ASSERTION.search(text):
        return 'assertion_failed', 'test_case'
    if SOURCE.search(text) and re.search(r':\s*(?:fatal )?error:', text):
        # XCTest failures with a source location are not compiler diagnostics.
        return ('test_failure', 'test_case') if CASE.search(text) or test_failure else ('compile_error', 'compile')
    if re.search(r'^(?:.*?\s)?(?:clang|swiftc|ld): (?:fatal )?error:', text):
        return 'compile_error', 'compile'
    return ('test_failure', 'test_case') if test_failure else (None, None)


def _diagnostic(text, path, locator, *, test_failure=False, case=None, node=None):
    kind, stage = _kind(text, test_failure=test_failure)
    if kind is None:
        return None
    match = CASE.search(text)
    result = dict(kind=kind, stage=stage, message=text, root_cause='unknown',
                  case=case or (match[1] if match else 'unknown'), source=_source(text),
                  expected='unknown', actual='unknown', evidence=[dict(path=str(path), **locator)])
    pair = EQUAL.search(text)
    if pair:
        result['comparison_operands'] = {'left': pair[1], 'right': pair[2], 'roles': 'unknown'}
    values = EXPLICIT_VALUES.search(text)
    if values:
        result.update(expected=values[1], actual=values[2])
    if node:
        for key in ('expected', 'actual'):
            if key in node:
                result[key] = node[key]
        # Xcode exported source locations, when present, refer to the run source.
        context = node.get('documentLocationInCreatingWorkspace', {})
        url = context.get('url', '') if isinstance(context, dict) else ''
        if isinstance(url, dict):
            url = url.get('_value', '')
        if isinstance(url, str) and '#StartingLineNumber=' in url:
            file, fragment = unquote(url).split('#', 1)
            line = re.search(r'StartingLineNumber=(\d+)', fragment)
            if line:
                result['source'] = dict(file=file.removeprefix('file://'), line=int(line[1]), column='unknown')
    return result


def _failure_nodes(value, pointer='$', in_failures=False):
    """Only known failure containers/text; never scrape arbitrary JSON warnings."""
    if isinstance(value, dict):
        text = value.get('failureText')
        if not isinstance(text, str) and in_failures:
            text = value.get('message')
            if isinstance(text, dict):
                text = text.get('_value')
        if isinstance(text, str):
            yield value, text, pointer
        for key, child in value.items():
            if isinstance(child, (dict, list)):
                yield from _failure_nodes(child, pointer + '/' + key,
                                          in_failures or key in ('testFailures', 'testFailureSummaries', 'failureMessages'))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from _failure_nodes(child, pointer + '/' + str(index), in_failures)


def failure_details(group, *, logs=(), summaries=(), receipts=(), provenance=None):
    """Read explicitly supplied files independently. Optional files belong to caller.

    provenance is reported context, not authenticated by this display module.
    No counts/qualification fields are consumed or produced.
    """
    errors, evidence, records, documents = [], [], [], []

    def read(path, json_object=False):
        path = Path(path)
        try:
            if any(p.is_symlink() for p in (path, *path.parents)) or not path.is_file():
                raise ValueError('Evidence must be a regular non-symlink file')
            if path.stat().st_size > MAX_BYTES:
                raise ValueError('Evidence exceeds display read budget')
            raw = path.read_bytes()
            evidence.append(dict(path=str(path), sha256=hashlib.sha256(raw).hexdigest()))
            text = raw.decode('utf-8-sig')
            if not json_object:
                return text
            value = json.loads(text)
            if not isinstance(value, dict):
                raise ValueError('Evidence JSON must be an object')
            return value
        except (OSError, ValueError, RecursionError) as error:
            errors.append(dict(path=str(path), kind='evidence_error', message=str(error)))
            return None

    for path in logs:
        text = read(path)
        if text is None:
            continue
        lines = text.splitlines()
        active_case = None
        for index, line in enumerate(lines):
            if 'Test Case ' in line and " started." in line:
                match = CASE.search(line)
                active_case = match[1] if match else None
            item = _diagnostic(line, path, {'line': index + 1}, case=active_case)
            if item:
                # Preserve generated location and the compiler's adjacent expansion note.
                if item['kind'] == 'compile_error' and '@__swiftmacro_' in item['source']['file']:
                    for offset, following in enumerate(lines[index + 1:index + 9], index + 2):
                        if re.search(r':\s*error:', following):
                            break
                        if "note: in expansion of macro" in following and SOURCE.search(following):
                            item['generated_source'] = item['source']
                            item['source'] = _source(following)
                            item['evidence'].append(dict(path=str(path), line=offset))
                            break
                records.append(item)
            if 'Test Case ' in line and re.search(r"' (?:passed|failed|skipped) ", line):
                active_case = None

    for path in summaries:
        doc = read(path, True)
        if doc is None:
            continue
        try:
            for node, text, pointer in _failure_nodes(doc):
                item = _diagnostic(text, path, {'json_pointer': pointer}, test_failure=True,
                                   case=node.get('testIdentifierString') or node.get('testName'), node=node)
                if item:
                    # Enrich only an unambiguous same-case, same-message raw event.
                    # Never attach another case's expected/actual to the first error.
                    def case_key(value):
                        parts = str(value).replace('/', ' ').replace('()', '').split()
                        return tuple(p.rsplit('.', 1)[-1] for p in parts)
                    matches = [r for r in records if r['kind'] == item['kind'] and text in r['message']
                               and r['case'] != 'unknown' and case_key(r['case']) == case_key(item['case'])]
                    if len(matches) == 1:
                        existing = matches[0]
                        for key in ('expected', 'actual'):
                            if existing[key] == 'unknown':
                                existing[key] = item[key]
                        if existing['source']['file'] == 'unknown':
                            existing['source'] = item['source']
                        existing['evidence'].extend(item['evidence'])
                    else:
                        records.append(item)
        except (ValueError, RecursionError) as error:
            errors.append(dict(path=str(path), kind='evidence_error', message=str(error)))

    for path in receipts:
        doc = read(path, True)
        if doc is not None:
            documents.append((path, doc))
    context = {key: (provenance or {}).get(key) or 'unknown'
               for key in ('source_commit', 'run_id', 'run_attempt')}
    for path, doc in documents:
        for key in context:
            if key in doc:
                if context[key] == 'unknown':
                    context[key] = doc[key]
                elif str(context[key]) != str(doc[key]):
                    errors.append(dict(path=str(path), kind='provenance_conflict', message=key + ' differs from display context'))
        text = doc.get('error', '')
        item = _diagnostic(text, path, {'json_pointer': '$/error'}) if isinstance(text, str) else None
        if item:
            records.append(item)
        elif doc.get('timed_out') is True:
            records.append(dict(kind='invocation_timeout', stage='invocation', message='Outer invocation timed_out=true',
                                root_cause='unknown', case='unknown', source=_source(''), expected='unknown', actual='unknown',
                                evidence=[dict(path=str(path), json_pointer='$/timed_out')]))
    first = records[0] if records else dict(kind='unknown', stage='unknown', root_cause='unknown',
                                          message='No concrete failure diagnostic available', case='unknown',
                                          source=_source(''), expected='unknown', actual='unknown', evidence=[])
    # Keep the first real diagnostic of each kind, not thousands of repeated errors.
    first_by_kind = {}
    for item in records:
        first_by_kind.setdefault(item['kind'], item)
    return dict(mode=MODE, group=group, provenance=context, provenance_verified=False,
                source_location_basis='run evidence only; current source not read',
                ordering='explicit log order, then xcresult, then receipts; not cross-file chronology',
                first_failure=first, first_by_kind=list(first_by_kind.values()),
                evidence_errors=errors, evidence=evidence)


def group_failure_details(folder, target, *, group=None, provenance=None):
    """Author-layout per-group filenames; missing primary log stays visible."""
    folder = Path(folder)
    def optional(names):
        return [folder / name for name in names if (folder / name).exists() or (folder / name).is_symlink()]
    return failure_details(group or folder.name, logs=[folder / (target + '.log')],
                           summaries=optional(('xcresult-summary.json', 'xcresult-tests.json')),
                           receipts=optional(('execution.json', 'selection.json', 'failure.json')),
                           provenance=provenance)


def failure_markdown(details):
    """Escaped display section shared by both existing summary chains."""
    def safe(value):
        return html.escape(str(value)).replace('|', '&#124;').replace('`', '&#96;').replace('\n', '<br>').replace('\r', '')
    lines = ['', '### Failure details — DISPLAY_ONLY (not qualification)', '']
    for detail in details:
        item = detail['first_failure']
        source = item['source']
        lines.append('- ' + safe(detail['group']) + ': ' + safe(item['kind']) + ' / stage=' + safe(item['stage']))
        lines.append('  - ' + safe(item['message']))
        lines.append('  - run source: ' + safe(source['file']) + ':' + safe(source['line']) +
                     '; context=' + safe(detail['provenance']) + '; root_cause=unknown')
        lines.append('  - expected=' + safe(item['expected']) + '; actual=' + safe(item['actual']))
        if 'comparison_operands' in item:
            lines.append('  - comparison operands (roles unknown): ' + safe(item['comparison_operands']))
        for entry in item['evidence']:
            lines.append('  - evidence: ' + safe(entry['path']) + ':' + safe(entry.get('line', entry.get('json_pointer'))))
        for error in detail['evidence_errors']:
            lines.append('  - evidence_error: ' + safe(error['path']) + ' — ' + safe(error['message']))
    return '\n'.join(lines) + '\n'
