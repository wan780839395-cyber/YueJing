"""Offline source contracts + synthetic evidence-reader regressions, NOT Swift/UIKit tests.

With --attachment, inspect one exported entryprobe JSON read-only. This is NON_GATE;
never turns diagnostics into a native-test pass, never launches or retries anything.
"""
import argparse
import copy
import json
import math
from pathlib import Path
import uuid

ROOT = Path(__file__).resolve().parents[1]
MAX_ATTACHMENT_BYTES = 131072


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def rect_matches(actual, expected):
    return (isinstance(actual, list) and isinstance(expected, list)
            and len(actual) == len(expected) == 4
            and all(number(x) for x in actual + expected)
            and actual[2] > 0 and actual[3] > 0 and expected[2] > 0 and expected[3] > 0
            and all(abs(a - b) <= 0.5 for a, b in zip(actual, expected)))


def classify(record):
    """Conservative read-only corroboration; false hittable is valid diagnostic data."""
    reasons = []
    def require(ok, reason):
        if not ok:
            reasons.append(reason)
    try:
        require(record['schema'] == 1 and record['kind'] == 'reading-entry-diagnostic', 'schema')
        require(record['nonGate'] is True and record['sequentialNotAtomic'] is True
                and record['hardWallClockBoundGuaranteed'] is False, 'scope')
        phase, nonce = record['phase'], record['nonce']
        require(phase in ('initial', 'failure'), 'phase')
        uuid.UUID(nonce)
        request = f'dev.yuejing.entry.{nonce}.{phase}'
        require(record['request'] == request, 'request')
        require(record['insideOriginalOpenBudget'] is (phase == 'initial')
                and record['functionalOutcomeAlreadyFailed'] is (phase == 'failure'), 'functional-budget-scope')
        require(record['validation'] == 'observed-sequential-not-atomic'
                and record['unknownReasons'] == [], 'producer-reported-unknown-or-incomplete')
        require(record['cacheWaitResult'] == 1 and type(record['cacheReads']) is int
                and 1 <= record['cacheReads'] <= 2 and record['maximumCacheReads'] == 2, 'cache-read-limit')
        env = record['appEnvelope']
        require(env['schema'] == 1 and env['maximumSamples'] == 2
                and env['automaticAXReadsTriggerSampling'] is False, 'cache-protocol')
        samples = env['samples']
        require(1 <= len(samples) <= 2 and set(samples) <= {'initial', 'failure'}, 'sample-limit')
        response = samples[phase]
        sample = response['appSample']
        require(env['nonce'] == sample['nonce'] == nonce
                and env['bundle'] == sample['bundle'] == 'dev.yuejing.app', 'fixture-identity')
        require(response['request'] == request and response['phase'] == phase, 'response-identity')
        require(response['status'] == sample['status'] == 'observed' and sample['schema'] == 1
                and sample['sampleKind'] == 'explicit-entry-request'
                and sample['sequence'] == (1 if phase == 'initial' else 2), 'native-sample-status')
        require(type(sample['appPID']) is int and sample['appPID'] > 0
                and env['appPID'] == sample['appPID'] != record['runnerPID'], 'process-identity')
        uuid.UUID(sample['routeID'])
        require(isinstance(sample['windowToken'], str) and bool(sample['windowToken']), 'window-identity')
        require(sample['keyWindow'] is True, 'not-key-window')
        require(record['stateValidation'] == 'observed-request-correlated-not-atomic', 'state-unknown')
        uuid.UUID(sample['readingWindowID'])
        require(sample['readingWindowID'] == sample['modelReadingWindowID']
                == sample['controllerReadingWindowID'], 'reading-window-version')
        for key in ('canInteract', 'visible', 'valid', 'suspended', 'hasPanel', 'exitRequested', 'loading', 'exitSaveFailed'):
            require(type(sample[key]) is bool, 'state-field-' + key)
        times = [record['startedUptime'], record['requestPostedUptime'], response['receivedUptime'],
                 sample['startedUptime'], sample['endedUptime'], response['completedUptime'],
                 record['cacheReadEndedUptime'], record['endedUptime']]
        require(all(number(t) for t in times) and times == sorted(times), 'time-order')
        require(number(record['cooperativeAllowanceSeconds']) and 0 < record['cooperativeAllowanceSeconds'] <= 2
                and number(record['cooperativeDeadlineUptime'])
                and abs(record['cooperativeDeadlineUptime'] - times[0] - record['cooperativeAllowanceSeconds']) < 0.000001
                and times[-1] <= record['cooperativeDeadlineUptime']
                and record['deadlineOverrunSeconds'] == 0, 'runner-budget')
        require(0 <= sample['endedUptime'] - sample['startedUptime'] <= 0.25, 'native-budget')
        if phase == 'initial':
            require(number(record['sharedBudgetAtEndSeconds']) and record['sharedBudgetAtEndSeconds'] >= 0, 'open-budget')
        else:
            first = samples['initial']['appSample']
            require(record['sameEntryIdentity'] is True
                    and all(first[k] == sample[k] for k in ('appPID', 'routeID', 'windowToken', 'nonce', 'bundle')),
                    'cross-phase-identity')
        obs = record['observations']
        for key in ('settings.exists', 'settings.enabled', 'settings.hittable', 'settings.frame', 'exit.frame'):
            value = obs[key]
            require(value['status'] == 'observed' and number(value['startedUptime']) and number(value['endedUptime'])
                    and record['cacheReadEndedUptime'] <= value['startedUptime'] <= value['endedUptime'] <= times[-1],
                    'observation-' + key)
        require(obs['settings.exists']['value'] is True, 'settings-missing')
        require(type(obs['settings.enabled']['value']) is bool and type(obs['settings.hittable']['value']) is bool,
                'settings-state-types')
        require(rect_matches(sample['exitScreenRect'], obs['exit.frame']['value']), 'exit-geometry')
        hit = sample['hit']
        require(rect_matches(hit['bottomScreenRect'], obs['settings.frame']['value'])
                and record['settingsGeometryValidation'] == 'matched-sequentially-not-atomic', 'settings-geometry')
        require(hit['status'] == 'observed' and hit['bottomStatus'] == 'observed-public-AX-frame'
                and hit['bottomAXSearch']['truncated'] is False and hit['bottomAXSearch']['matches'] == 1,
                'native-AX-search')
        require(isinstance(hit['bottomHitChain'], list) and 1 <= len(hit['bottomHitChain']) <= 6, 'bounded-hit-chain')
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
        reasons.append('malformed-or-missing-fields')
    return {'kind': 'NON_GATE_OFFLINE_ATTACHMENT_INSPECTION',
            'observation': 'corroborated-sequential-not-atomic' if not reasons else 'unknown',
            'unknown_reasons': reasons, 'native_test_result': 'not evaluated'}


def fixture():
    """Deliberately synthetic attachment; not produced by Swift or an App."""
    nonce = '11111111-1111-4111-8111-111111111111'
    route = '22222222-2222-4222-8222-222222222222'
    reading = '33333333-3333-4333-8333-333333333333'
    request = f'dev.yuejing.entry.{nonce}.initial'
    sample = dict(schema=1, status='observed', sampleKind='explicit-entry-request', sequence=1,
                  nonce=nonce, bundle='dev.yuejing.app', appPID=101, routeID=route, windowToken='synthetic-window',
                  keyWindow=True, readingWindowID=reading, modelReadingWindowID=reading, controllerReadingWindowID=reading,
                  canInteract=True, visible=True, valid=True, suspended=False, hasPanel=False, exitRequested=False,
                  loading=False, exitSaveFailed=False, startedUptime=10.03, endedUptime=10.08,
                  exitScreenRect=[20, 30, 44, 44], hit=dict(status='observed', bottomStatus='observed-public-AX-frame',
                  bottomScreenRect=[189.5, 611, 144, 44], bottomAXSearch=dict(truncated=False, matches=1),
                  bottomHitChain=[dict(className='synthetic-only')]))
    response = dict(request=request, phase='initial', status='observed', receivedUptime=10.02,
                    completedUptime=10.09, appSample=sample)
    obs = {k: dict(status='observed', startedUptime=10.2, endedUptime=10.21, value=v) for k, v in {
        'settings.exists': True, 'settings.enabled': True, 'settings.hittable': False,
        'settings.frame': [189.5, 611, 144, 44], 'exit.frame': [20, 30, 44, 44]}.items()}
    return dict(schema=1, kind='reading-entry-diagnostic', nonGate=True, sequentialNotAtomic=True,
                hardWallClockBoundGuaranteed=False, phase='initial', nonce=nonce, request=request,
                insideOriginalOpenBudget=True, functionalOutcomeAlreadyFailed=False,
                validation='observed-sequential-not-atomic', unknownReasons=[], runnerPID=202,
                cacheWaitResult=1, cacheReads=1, maximumCacheReads=2,
                startedUptime=10.0, requestPostedUptime=10.01, cacheReadEndedUptime=10.1, endedUptime=10.3,
                cooperativeAllowanceSeconds=2.0, cooperativeDeadlineUptime=12.0, deadlineOverrunSeconds=0,
                sharedBudgetAtEndSeconds=17.0, stateValidation='observed-request-correlated-not-atomic',
                settingsGeometryValidation='matched-sequentially-not-atomic', observations=obs,
                appEnvelope=dict(schema=1, maximumSamples=2, automaticAXReadsTriggerSampling=False,
                                 nonce=nonce, bundle='dev.yuejing.app', appPID=101, samples={'initial': response}))


def regressions():
    count = 0
    good = fixture()
    assert classify(good)['observation'] == 'corroborated-sequential-not-atomic'
    count += 1  # false hittable is an observation, not a pass or a malformed record.
    mutations = [
        ('validation', 'unknown'), ('unknownReasons', ['budget']), ('nonGate', False), ('schema', 9),
        ('sequentialNotAtomic', False), ('hardWallClockBoundGuaranteed', True), ('nonce', 'bad'),
        ('request', 'other-request'), ('phase', 'later'), ('insideOriginalOpenBudget', False),
        ('functionalOutcomeAlreadyFailed', True), ('cacheReads', 3), ('cacheReads', 0), ('cacheReads', True),
        ('cacheWaitResult', 2), ('cooperativeAllowanceSeconds', 3), ('cooperativeDeadlineUptime', 10.2),
        ('deadlineOverrunSeconds', 0.1), ('sharedBudgetAtEndSeconds', -1), ('endedUptime', float('nan')),
        ('requestPostedUptime', 11), ('stateValidation', 'unknown'), ('runnerPID', 101),
        ('appEnvelope.nonce', 'other'), ('appEnvelope.bundle', 'wrong'), ('appEnvelope.appPID', 999),
        ('appEnvelope.maximumSamples', 3), ('appEnvelope.automaticAXReadsTriggerSampling', True),
        ('appEnvelope.samples.initial.request', 'other'), ('appEnvelope.samples.initial.phase', 'failure'),
        ('appEnvelope.samples.initial.status', 'unknown'), ('appEnvelope.samples.initial.receivedUptime', 9),
        ('appEnvelope.samples.initial.appSample.schema', 2), ('appEnvelope.samples.initial.appSample.sequence', 2),
        ('appEnvelope.samples.initial.appSample.sampleKind', 'getter'), ('appEnvelope.samples.initial.appSample.status', 'unknown'),
        ('appEnvelope.samples.initial.appSample.appPID', -1), ('appEnvelope.samples.initial.appSample.routeID', 'bad'),
        ('appEnvelope.samples.initial.appSample.windowToken', ''), ('appEnvelope.samples.initial.appSample.keyWindow', False),
        ('appEnvelope.samples.initial.appSample.controllerReadingWindowID', 'other'),
        ('appEnvelope.samples.initial.appSample.canInteract', 'true'),
        ('appEnvelope.samples.initial.appSample.startedUptime', 9),
        ('appEnvelope.samples.initial.appSample.endedUptime', 10.9),
        ('appEnvelope.samples.initial.appSample.exitScreenRect', [21, 30, 44, 44]),
        ('appEnvelope.samples.initial.appSample.hit.bottomScreenRect', [189.5, 611, 144, 0]),
        ('appEnvelope.samples.initial.appSample.hit.bottomAXSearch.truncated', True),
        ('appEnvelope.samples.initial.appSample.hit.bottomAXSearch.matches', 2),
        ('appEnvelope.samples.initial.appSample.hit.bottomStatus', 'unknown'),
        ('appEnvelope.samples.initial.appSample.hit.bottomHitChain', []),
        ('observations.settings.hittable', None),
    ]
    # Observation labels contain dots: use direct mutation separately.
    mutations = mutations[:-1]
    for path, replacement in mutations:
        value = copy.deepcopy(good)
        keys = path.split('.')
        parent = value
        for key in keys[:-1]: parent = parent[key]
        parent[keys[-1]] = replacement
        assert classify(value)['observation'] == 'unknown', path
        count += 1
    for missing in ('appEnvelope', 'observations', 'phase', 'validation', 'cacheReads'):
        value = copy.deepcopy(good); del value[missing]
        assert classify(value)['observation'] == 'unknown'
        count += 1
    for replacement in ('false', None):
        value = copy.deepcopy(good); value['observations']['settings.hittable']['value'] = replacement
        assert classify(value)['observation'] == 'unknown'
        count += 1
    failure = copy.deepcopy(good)
    failure.update(phase='failure', insideOriginalOpenBudget=False, functionalOutcomeAlreadyFailed=True, sameEntryIdentity=True)
    failure['request'] = failure['request'].replace('.initial', '.failure')
    response = copy.deepcopy(failure['appEnvelope']['samples']['initial'])
    response.update(phase='failure', request=failure['request'])
    response['appSample']['sequence'] = 2
    failure['appEnvelope']['samples']['failure'] = response
    assert classify(failure)['observation'] == 'corroborated-sequential-not-atomic'; count += 1
    response['appSample']['windowToken'] = 'other-window'
    assert classify(failure)['observation'] == 'unknown'; count += 1
    for malformed in (None, [], {}, {'schema': 1}):
        assert classify(malformed)['observation'] == 'unknown'; count += 1
    return count


def source_contracts():
    files = {name: (ROOT / name).read_text(encoding='utf-8') for name in (
        'App/Reading/ReaderEntryProbe.swift', 'App/Reading/ReaderScreen.swift',
        'App/Reading/ReaderViewController.swift', 'Tests/YueJingUITests/ReadingEntryEvidence.swift',
        'Tests/YueJingUITests/ReadingFlowUITests.swift')}
    probe = files['App/Reading/ReaderEntryProbe.swift']
    runner = files['Tests/YueJingUITests/ReadingEntryEvidence.swift']
    flow = files['Tests/YueJingUITests/ReadingFlowUITests.swift']
    controller = files['App/Reading/ReaderViewController.swift']
    checks = []
    def check(condition, name):
        assert condition, name
        checks.append(name)
    for token in ('#if DEBUG', 'ReadingUITestFixture.isRequested', 'YUEJING_READER_ENTRY_PROBE', 'UUID(uuidString:',
                  'names.isEmpty', 'consumed.count < 2', 'consumed.insert(phase).inserted', 'private weak var store:',
                  'private weak var endpoint:', 'get { ReaderEntryProbe.shared.cachedValue }',
                  'raw.utf8.count <= 24576', 'data.count <= 65536', 'firstRoute != route || firstWindow != window'):
        check(token in probe, 'app:' + token)
    check(probe.rstrip().endswith('#endif'), 'entire-new-App-file-debug-only')
    check(probe.count('store.entryValue(') == 1, 'single-native-sample-callsite')
    check('hitTest' not in probe[probe.index('override var accessibilityValue'):], 'getter-does-not-sample')
    for token in ('cacheReads < 2', 'min(2.0, max(0, sharedDeadline?.timeIntervalSinceNow ?? 2.0))',
                  'CFNotificationCenterPostNotification', 'raw.utf8.count <= 65536', 'started.insert(key).inserted',
                  'failed.insert(key).inserted', 'hardWallClockBoundGuaranteed', 'deadlineOverrunSeconds',
                  'unknownReasons', 'sameEntryIdentity', 'sampleAgeAtReadSeconds', 'settingsGeometryValidation'):
        check(token in runner, 'runner:' + token)
    for forbidden in ('XCTAssert', 'XCTFail(', '.tap()', '.swipe', '.launch()', '.terminate()', 'sleep(', 'Timer(', 'URLSession'):
        check(forbidden not in runner, 'runner-no-action-or-assert:' + forbidden)
    check(runner.count('CFNotificationCenterPostNotification(') == 1, 'one-notification-no-request-retry')
    check(runner.index('checkpoint: "started"') < runner.index('CFNotificationCenterPostNotification'), 'started-evidence-first')
    check(runner.index('checkpoint: "app-cache"') < runner.index('let settings = app.buttons'), 'cache-evidence-before-state-queries')
    check('let deadline = Date().addingTimeInterval(20)' in flow, 'original-open-budget')
    check('let deadline = Date().addingTimeInterval(10)' in flow, 'original-exit-budget')
    check('exists == true AND hittable == true' in flow, 'original-hittable-predicate')
    check(flow.index('let result = XCTWaiter.wait(for: [ready], timeout: timeout)')
          < flow.index('if result != .completed { onFailure?() }') < flow.index('XCTAssertEqual(result, .completed)'),
          'functional-outcome-held-before-diagnostics-and-original-assertion')
    check('if entryDiagnostic { ReadingEntryEvidence.settingsFailed(app, key: key) }' in flow, 'first-open-only-failure-hook')
    check(flow.index('The expected synthetic book must have content geometrically visible')
          < flow.index('ReadingEntryEvidence.beforeSettings') < flow.index('onFailure: {'), 'entry-capture-position')
    for token in ('entrySequence == nil', 'sequence < 32', 'started + 0.25', 'seen.count < 128 && !expired()',
                  'depth < 8', 'count <= 32', '0..<6', 'entry-sample-deadline'):
        check(token in controller, 'native-bound:' + token)
    import task3_test_inventory as inventory
    inventory.validate_source()
    check(inventory.TOTAL == 138, 'reviewed-138-unique-cases')
    ui = (ROOT / 'scripts/run_reading_ui_tests.py').read_text(encoding='utf-8')
    check('export_ui_evidence(out, provenance, code)' in ui, 'existing-attachment-export-retained')
    check('"exported_files": list(files.values())' in ui, 'new-json-exported-without-gate-change')
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--attachment', type=Path, help='Read one existing exported entryprobe JSON; never runs tests')
    args = parser.parse_args()
    if args.attachment:
        if not args.attachment.is_file() or args.attachment.stat().st_size > MAX_ATTACHMENT_BYTES:
            raise ValueError('Expected bounded regular attachment file')
        try:
            value = json.loads(args.attachment.read_text(encoding='utf-8'))
        except (UnicodeError, ValueError):
            value = None
        print(json.dumps(classify(value), ensure_ascii=False, indent=2))
    else:
        checks = source_contracts()
        count = regressions()
        print(json.dumps(dict(kind='OFFLINE_ONLY_NOT_SWIFT_OR_UIKIT_EXECUTION', source_checks=len(checks),
                             synthetic_reader_regressions=count, checks=checks, native_tests_run=0), indent=2))


if __name__ == '__main__':
    main()
