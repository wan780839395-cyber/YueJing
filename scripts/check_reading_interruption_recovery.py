"""Offline interruption source/guard checks. Never compiles Swift or simulates UITouch.

--baseline points at this batch's ignored, pre-edit baseline.json. Negative controls
mutate source strings only; the pre-edit production source must fail a semantic
bridge assertion, independently of hash/scope protection.
"""
import argparse
import ast
import difflib
import hashlib
import json
from pathlib import Path
import re
import task3_test_inventory as inventory

ROOT = Path(__file__).resolve().parents[1]
SCREEN = 'App/Reading/ReaderScreen.swift'
VIEWPORT = 'App/Reading/ReaderViewport.swift'
VC = 'App/Reading/ReaderViewController.swift'
HOST = 'Tests/YueJingHostTests/ReaderInteractionInterruptionTests.swift'
NAMES = ('interruptedDecelerationRecoversOnSameControllerWithoutMovingAnchor',
         'interruptionRevokesOldTouchAndAcceptsFreshIntent',
         'momentumAtTouchBeginStillStopsBeforeANewIdleTouchCanToggle',
         'viewportInterruptionForwardingIsIdempotentAndDetachedControllerIsInert')
EXISTING = (SCREEN, VIEWPORT, VC, 'scripts/task3_test_inventory.py',
            'scripts/check_reading_entry_diagnostics.py', 'scripts/check_device_build_validation_entry.py')
NEW = (HOST, 'scripts/check_reading_interruption_recovery.py', 'docs/READING_INTERRUPTION_RECOVERY_LOCAL.md')
# Reviewed original 1-based changed lines and insertion-after positions. No whole-file masking.
LEDGER = {
    SCREEN: ([], [34, 103]),
    VIEWPORT: ([], [8, 17, 21, 35, 47, 56]),
    VC: ([(20, 23), (41, 46), (145, 148), (151, 156), (167, 167), (175, 175),
          (178, 178), (220, 221), (269, 272)], [3, 63, 65]),  # equal blank/closing-brace alignment
    'scripts/task3_test_inventory.py': ([(41, 41), (44, 44)], [35]),
    'scripts/check_reading_entry_diagnostics.py': ([(258, 258)], []),
    'scripts/check_device_build_validation_entry.py': ([(96, 97)], []),
}


def function(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    for i in range(opening + 1, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}': depth -= 1
        if depth == 0: return text[start:i + 1]
    raise AssertionError('unbalanced-source-function:' + marker)


def source_contracts(s):
    checks = []
    def need(ok, label):
        assert ok, label
        checks.append(label)
    screen, viewport, vc, host = (s[p] for p in (SCREEN, VIEWPORT, VC, HOST))
    need('model.viewport.setInteractionActive(phase == .active)' in screen, 'synchronous-scene-interruption-bridge')
    phase = function(screen, '.onChange(of: scenePhase)')
    need(phase.index('model.viewport.setInteractionActive(') < phase.index('mutateTools') < phase.index('Task {'),
         'bridge-before-tools-and-existing-save-task')
    need('interactionActive: scenePhase == .active,' in screen, 'initial-phase-propagated-without-new-task')
    need('guard scenePhase == phase else { return }' in phase and
         'if phase == .active { await model.resume() } else { await model.suspend() }' in phase,
         'original-async-phase-guard-and-save-resume-retained')
    forward = function(viewport, 'func setInteractionActive(')
    need('guard interactionActive != active else { return }' in forward and
         'interactionActive = active\n        controller?.setInteractionActive(active)' in forward,
         'handle-idempotent-current-controller-forwarding')
    attach = function(viewport, 'func attach(')
    detach = function(viewport, 'func detach(')
    need('old !== value' in attach and 'restoration = old.restorationPoint() ?? restoration' in attach and
         'old.detachCallbacks()' in attach and 'controller = value\n        value.setInteractionActive(interactionActive)' in attach,
         'replacement-keeps-anchor-and-inherits-current-phase')
    need('guard controller === value else { return }' in detach and
         'restoration = value.restorationPoint() ?? restoration; controller = nil\n        value.detachCallbacks()' in detach,
         'late-detach-cannot-clear-new-controller-and-old-is-inert')
    make = function(viewport, 'func makeUIViewController(')
    update = function(viewport, 'func updateUIViewController(')
    need(make.index('handle.setInteractionActive(interactionActive)') < make.index('handle.attach(controller)') and
         update.index('guard handle.controller === controller') < update.index('handle.setInteractionActive(interactionActive)'),
         'initial-before-attach-and-update-owner-guard')
    boundary = function(vc, 'mutating func setActive(')
    need('guard active != value else { return }' in boundary, 'context-phase-is-idempotent')
    need('active = value; generation = UUID(); touch = nil' in boundary, 'phase-revokes-old-touch-and-generation')
    need('toolDecelerating = value && decelerating' in boundary, 'inactive-clears-shadow-active-calibrates-real-inertia')
    begin = function(vc, 'mutating func begin(')
    need('guard active, let intent else { return nil }' in begin and
         'Touch(generation: generation, intent: intent,' in begin and 'return value.id' in begin,
         'fresh-touch-requires-active-and-current-intent')
    need('beganDuringDeceleration: decelerating || toolDecelerating, beganDuringDragging: dragging' in begin,
         'touch-begin-retains-real-and-shadow-inertia-and-drag-latches')
    latch = function(vc, 'mutating func latch(')
    need('value.id == id, value.generation == generation' in latch and
         'value.beganDuringDeceleration = value.beganDuringDeceleration || decelerating || toolDecelerating' in latch and
         'value.beganDuringDragging = value.beganDuringDragging || dragging' in latch,
         'recognizer-begin-only-strengthens-the-same-touch-latches')
    finish = function(vc, 'mutating func finish(')
    need('guard active, let value = touch, value.id == id, value.generation == generation else { return nil }' in finish,
         'old-end-cannot-revive-or-consume-fresh-touch')
    need('beganDuringDeceleration: value.beganDuringDeceleration' in finish and
         'dragging: value.beganDuringDragging || dragging, decelerating: decelerating, voiceOver: voiceOver' in finish and
         'touch = nil' in finish and 'toolDecelerating = decelerating' in finish,
         'first-momentum-touch-stops-before-next-idle-touch-without-stopping-UIKit')
    cancel = function(vc, 'mutating func cancel(')
    need('guard touch?.id == id else { return }' in cancel and 'touch = nil' in cancel,
         'cancel-revokes-only-matching-touch')
    controller_phase = function(vc, 'func setInteractionActive(')
    need('guard interactionContext.active != active else { return }' in controller_phase and
         'interactionContext.setActive(active, decelerating: table.isDecelerating)' in controller_phase and
         'toolsTap.isEnabled = active' in controller_phase, 'controller-phase-calibrates-and-cancels-existing-recognizer')
    need('setInteractionActive(false)' in function(vc, 'func detachCallbacks(') and
         'toolIntent = nil; onToolsInteraction = nil' in function(vc, 'func detachCallbacks('), 'detached-context-and-callbacks-revoked')
    need('interactionContext.begin(intent: toolIntent?(), dragging: table.isDragging, decelerating: table.isDecelerating)' in
         function(vc, 'func beginToolTouch('), 'fresh-production-touch-samples-real-UIKit-not-forced-idle')
    need('interactionContext.latch(id, dragging: table.isDragging, decelerating: table.isDecelerating)' in vc and
         'interactionContext.finish(id, dragging: table.isDragging,' in vc and
         'decelerating: table.isDecelerating, voiceOver: UIAccessibility.isVoiceOverRunning)' in vc,
         'production-latch-and-end-sample-real-state')
    need('toolsTap.touchID = beginToolTouch()' in function(vc, 'func gestureRecognizer(') and
         'endToolTouch(toolsTap.touchID)' in function(vc, '@objc private func bodyTapped(') and
         'self?.latchToolTouch(id)' in vc and 'self?.cancelToolTouch(id)' in vc and
         'onToolsInteraction?(.tap(intent, decision))' in function(vc, 'func endToolTouch('),
         'helper-is-used-by-real-delegate-gesture-and-callback-not-test-only-model')
    need('onTouchCancelled?(touchID); touchID = nil' in function(vc, 'override func touchesCancelled(') and
         'onTouchCancelled?(touchID); touchID = nil' in function(vc, 'override func reset('), 'recognizer-cancel-and-reset-invalidate-token')
    need('interactionContext.draggingBegan()' in function(vc, 'func scrollViewWillBeginDragging(') and
         'interactionContext.draggingEnded(decelerating: decelerate)' in function(vc, 'func scrollViewDidEndDragging(') and
         'interactionContext.decelerationEnded()' in function(vc, 'func scrollViewDidEndDecelerating('),
         'real-scroll-delegates-maintain-production-shadow')
    need('toolsTap.require(toFail: table.panGestureRecognizer)' in vc and
         'toolsTap.cancelsTouchesInView = false' in vc and 'ReadingToolsGesturePolicy.central(' in vc,
         'original-pan-central-and-stop-on-touch-policy-retained')
    context = vc[vc.index('struct ReaderToolTouchContext'):vc.index('@MainActor\nfinal class ReaderViewController')]
    need(all(x not in context + controller_phase + begin + finish for x in
             ('Task {', 'Timer(', 'DispatchQueue', 'setContentOffset', 'LibraryService', 'ReadingAnchor', 'URLSession', 'NotificationCenter')),
         'transient-helper-no-async-save-position-network-observer')
    need('"latchedDecelerating": interactionContext.touch?.beganDuringDeceleration ?? false' in vc and
         '"toolDecelerating": interactionContext.toolDecelerating' in vc, 'debug-keys-read-current-state-without-mutation')
    need(tuple(re.findall(r'@Test\s+func\s+(\w+)\(', host)) == NAMES and
         '@MainActor\n@Suite(.serialized)' in host and '@testable import YueJing' in host,
         'exactly-four-ordinary-serial-host-identities')
    need('table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: true)' in host and
         'table.contentOffset == offset' in host and 'handle.controller === controller' in host and
         'controller.endToolTouch(old) == nil' in host and 'controller.endToolTouch(momentum) == .stopMomentum' in host and
         'handle.detach(old)' in host and 'empty.setInteractionActive(false)' in host,
         'host-real-controller-production-helper-anchor-oldtouch-momentum-and-ownership-assertions')
    need('func withController(' in host and 'reader.window(around: anchor' in host and
         'UIWindow(windowScene: scene)' in host and 'NOT native UITouch reproduction' in host,
         'host-self-contained-synthetic-reading-window-and-honest-injection-label')
    return checks


def protection(s, baseline):
    b = json.loads(baseline.read_text(encoding='utf-8'))
    assert b['head'] == 'fd4b925192cf97f9afca459be703b1ac5510a10f', 'wrong-batch-baseline'
    assert b['existing'] == list(EXISTING) and b['new'] == list(NEW), 'baseline-scope-drift'
    ledger = {}
    for p, (ranges, inserts) in LEDGER.items():
        raw = (baseline.parent / 'baseline' / p).read_bytes()
        assert hashlib.sha256(raw).hexdigest() == b['before'][p], 'baseline-copy-hash:' + p
        before = raw.decode('utf-8').splitlines(keepends=True)
        after = s[p].splitlines(keepends=True)
        changed = []
        for kind, i, j, k, l in difflib.SequenceMatcher(None, before, after, autojunk=False).get_opcodes():
            if kind == 'equal': continue
            allowed = {n for a, z in ranges for n in range(a, z + 1)}
            assert all(n in allowed for n in range(i + 1, j + 1)), 'outside-reviewed-original-lines:' + p
            assert i != j or i in inserts or any(a - 1 <= i <= z for a, z in ranges), 'outside-reviewed-insertion:' + p
            changed.append(dict(kind=kind, before=[i + 1, j], after=[k + 1, l]))
        ledger[p] = changed
        if p in (SCREEN, VIEWPORT, VC):
            original = ''.join(before)
            for token in ('Task {', '.task(', 'Timer(', 'DispatchQueue', 'addGestureRecognizer(',
                          'setContentOffset(', 'NotificationCenter', '.onAppear', '.zIndex(', 'URLSession'):
                assert s[p].count(token) == original.count(token), 'new-async-gesture-save-or-lifecycle-work:' + p + ':' + token
        if p == 'scripts/check_reading_entry_diagnostics.py':
            normalized = s[p].replace("check(inventory.TOTAL == 142, 'reviewed-142-unique-cases')",
                                      "check(inventory.TOTAL == 138, 'reviewed-138-unique-cases')")
            assert normalized == ''.join(before), 'entry-adapter-not-count-only'
        if p == 'scripts/check_device_build_validation_entry.py':
            normalized = s[p].replace('== 142 and report["all_declared"] == 143', '== 138 and report["all_declared"] == 139')
            normalized = normalized.replace('reviewed_142_selected_declarations', 'reviewed_138_selected_declarations')
            assert normalized == ''.join(before), 'loader-adapter-not-count-only'
    # Original test bodies, workflow/project, VM/route/save, dock, skill/private hashes: never read private text.
    tables = [b['protected_tracked'], b['protected_extra']]
    for table in tables:
        for p, expected in table.items():
            assert hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == expected, 'protected-hash-drift:' + p
    old = ast.parse((baseline.parent / 'baseline/scripts/task3_test_inventory.py').read_text(encoding='utf-8'))
    old_files = next(ast.literal_eval(n.value) for n in old.body if isinstance(n, ast.Assign)
                     and any(isinstance(t, ast.Name) and t.id == 'FILES' for t in n.targets))
    assert {p: n for p, n in inventory.FILES.items() if p != HOST.removeprefix('Tests/')} == old_files, 'original-139-identities-changed'
    result = inventory.validate_source(ROOT)
    assert result['selected'] == 142 and result['all_declared'] == 143 and inventory.COUNTS['YueJingHostTests'] == 6
    assert 'YueJingHostTests' not in inventory.SWIFT_GROUPS and result['native_executions'] == 0
    return dict(ledger=ledger, protected_tracked=len(tables[0]), protected_extra=len(tables[1]),
                protected_unique=len(set(tables[0]) | set(tables[1])), selected=142, declared=143, original_declared=139)


def negative_controls(s, baseline):
    mutations = [
        ('missing-phase-bridge', SCREEN, 'model.viewport.setInteractionActive(phase == .active)', '()'),
        ('missing-initial-phase', SCREEN, 'interactionActive: scenePhase == .active,', 'interactionActive: true,'),
        ('stale-shadow-after-interruption', VC, 'toolDecelerating = value && decelerating', 'toolDecelerating = toolDecelerating'),
        ('old-touch-generation-revived', VC, 'active = value; generation = UUID(); touch = nil', 'active = value'),
        ('old-end-consumes-fresh-touch', VC, 'guard active, let value = touch, value.id == id, value.generation == generation else { return nil }', 'guard let value = touch else { return nil }'),
        ('remove-begin-momentum-latch', VC, 'beganDuringDeceleration: value.beganDuringDeceleration', 'beganDuringDeceleration: decelerating'),
        ('force-every-tap-idle', VC, 'interactionContext.begin(intent: toolIntent?(), dragging: table.isDragging, decelerating: table.isDecelerating)', 'interactionContext.begin(intent: toolIntent?(), dragging: false, decelerating: false)'),
        ('repeated-active-breaks-fresh-touch', VIEWPORT, 'guard interactionActive != active else { return }', '// no idempotence'),
        ('repeated-controller-active-breaks-fresh-touch', VC, 'guard interactionContext.active != active else { return }', '// no idempotence'),
        ('old-controller-callbacks-survive', VIEWPORT, 'old.detachCallbacks()', '// callback leak'),
        ('late-detach-clears-new-owner', VIEWPORT, 'guard controller === value else { return }', '// no ownership guard'),
        ('replacement-forgets-inactive', VIEWPORT, 'value.setInteractionActive(interactionActive)', 'value.setInteractionActive(true)'),
        ('recognizer-reset-keeps-old-token', VC, 'onTouchCancelled?(touchID); touchID = nil', '// stale token'),
        ('cancel-clears-fresh-touch', VC, 'guard touch?.id == id else { return }', '// wrong cancellation'),
        ('inactive-accepts-touch', VC, 'guard active, let intent else { return nil }', 'guard let intent else { return nil }'),
        ('test-only-helper-no-production-begin', VC, 'toolsTap.touchID = beginToolTouch()', 'toolsTap.touchID = UUID()'),
    ]
    rejected = []
    for label, p, old, new in mutations:
        assert old in s[p], 'negative-control-not-applied:' + label
        alt = dict(s); alt[p] = alt[p].replace(old, new)
        try: source_contracts(alt)
        except (AssertionError, ValueError) as error: rejected.append(dict(name=label, by=str(error)))
        else: raise AssertionError('accepted-negative:' + label)
    preedit = dict(s)
    for p in (SCREEN, VIEWPORT, VC): preedit[p] = (baseline.parent / 'baseline' / p).read_text(encoding='utf-8')
    try: source_contracts(preedit)
    except AssertionError as error:
        assert str(error) == 'synchronous-scene-interruption-bridge'
        rejected.append(dict(name='actual-preedit-production-semantic-rejection', by=str(error)))
    else: raise AssertionError('preedit-was-not-rejected')
    # Mutating business/save code outside the exact line ledger must fail even if all semantic tokens remain.
    alt = dict(s); alt[SCREEN] = alt[SCREEN].replace('succeeded = await model.close()', 'succeeded = true')
    try: protection(alt, baseline)
    except AssertionError as error:
        assert str(error) == 'outside-reviewed-original-lines:' + SCREEN
        rejected.append(dict(name='save-tail-not-masked', by=str(error)))
    else: raise AssertionError('save-tail-was-not-protected')
    return rejected


# Explicit successor phase. The original LEDGER, phase and 143/142 inventory stay frozen.
THEME_HOST = 'Tests/YueJingHostTests/ReaderThemeUpdateTests.swift'
THEME_NAMES = ('sameThemeUpdatesAreIdempotentAndRealChangesStillApply',
               'sameThemeDoesNotPreventANewWindowFromApplying')
THEME_EXISTING = (VC, EXISTING[3], EXISTING[4], EXISTING[5], NEW[1])
THEME_NEW = (THEME_HOST, 'docs/READER_DOCK_VISIBILITY_UPDATE_LOCAL.md')
CELL = 'App/Reading/ReadingCell.swift'
CACHE = '    private var appliedTheme: ReaderTheme?\n'
OLD_THEME = '''    func setTheme(_ theme: ReaderTheme) {
        loadViewIfNeeded()
        view.backgroundColor = theme.background; table.backgroundColor = theme.background
    }
'''
NEW_THEME = '''    @discardableResult
    func setTheme(_ theme: ReaderTheme) -> Bool {
        guard appliedTheme != theme else { return false }
        loadViewIfNeeded()
        let background = theme.background
        view.backgroundColor = background; table.backgroundColor = background
        appliedTheme = theme
        return true
    }
'''
THEME_INVENTORY_LINE = ('    "YueJingHostTests/ReaderThemeUpdateTests.swift": """' +
                        ' '.join(THEME_NAMES) + '""",\n')
THEME_ARGS = """    parser.add_argument('--theme-update', action='store_true', help='Explicit same-theme successor; not the historical phase')
    parser.add_argument('--previous-stage', type=Path, help='Frozen nine-candidate baseline.json for the successor')
"""
THEME_BRANCH = """    if args.theme_update:
        if not args.previous_stage: parser.error('--theme-update requires --previous-stage')
        theme_main(args.baseline, args.previous_stage)
        return
    if args.previous_stage: parser.error('--previous-stage requires --theme-update')
"""


def theme_contracts(s):
    checks = []
    def need(ok, label):
        assert ok, label
        checks.append(label)
    vc, viewport, host = (s[p] for p in (VC, VIEWPORT, THEME_HOST))
    theme = function(vc, 'func setTheme(')
    gate = 'guard appliedTheme != theme else { return false }'
    need(gate in theme and theme.index(gate) < theme.index('loadViewIfNeeded()'),
         'same-theme-guard-before-container-work')
    need(CACHE in vc and vc.count('private var appliedTheme') == 1,
         'initial-nil-cache-including-first-paper')
    need(theme.count('theme.background') == 1 and
         'view.backgroundColor = background; table.backgroundColor = background' in theme,
         'one-color-value-two-real-containers')
    need(theme.index('table.backgroundColor = background') < theme.index('appliedTheme = theme') < theme.index('return true'),
         'changed-theme-applies-before-remembering-and-returns-true')
    need(theme == NEW_THEME[NEW_THEME.index('func setTheme('):].rstrip(),
         'only-container-colors-no-render-reload-display-or-async-work')
    update = function(viewport, 'func updateUIViewController(')
    order = ['guard handle.controller === controller', 'handle.setInteractionActive(interactionActive)',
             'controller.toolIntent = toolIntent; controller.onToolsInteraction = onToolsInteraction',
             '\n        controller.setTheme(preferences.theme)\n',
             'guard let window, controller.window?.id != window.id else { return }',
             'controller.apply(window, userNavigation: navigation, restoring:',
             'handle.applied(controller)', 'onApplied(window.id)']
    need(all(t in update for t in order) and [update.index(t) for t in order] == sorted(update.index(t) for t in order),
         'viewport-phase-callbacks-and-new-window-apply-not-gated-by-theme-result')
    need('cell.render(window.slices[indexPath.row], preferences: window.preferences)' in
         function(vc, 'func tableView(_ tableView: UITableView, cellForRowAt') and
         'accessibilityLabel = value.lines.map(\\.text).joined()' in s[CELL],
         'body-render-and-AX-owned-by-cell-window-path-not-container-setter')
    need(tuple(re.findall(r'@Test\s+func\s+(\w+)\(', host)) == THEME_NAMES and
         '@MainActor\n@Suite(.serialized)' in host and '@testable import YueJing' in host,
         'two-ordinary-serial-mainactor-host-identities')
    need('#expect(!controller.isViewLoaded)' in host and '#expect(controller.setTheme(.paper))' in host and
         '#expect(!controller.setTheme(.paper))' in host and all('#expect(controller.setTheme(.' + t + '))' in host for t in ('dark', 'light')),
         'host-first-paper-repeat-and-real-theme-change-results')
    need('#expect(controller.view.backgroundColor == theme.background)' in host and
         '#expect(table.backgroundColor == theme.background)' in host,
         'host-real-colors-not-just-boolean-claims')
    need('controller.apply(second, userNavigation: false)' in host and
         'controller.window?.id == second.id' in host and '#expect(newText != oldText)' in host and
         'controller.apply(dark, userNavigation: false)' in host and
         '#expect(cell.contentView.backgroundColor == ReaderTheme.dark.background)' in host,
         'host-second-window-body-and-matching-changed-theme-window-apply')
    need('reader.window(around: firstAnchor' in host and 'reader.window(around: secondAnchor' in host and
         'first.id != second.id && second.id != dark.id' in host and
         'rawByteOffset: reader.source.metadata.bomByteCount + firstChapter.utf8.count' in host and
         'rendered.slices[path.row].lines.map(\\.text).joined()' in host and
         'accessibilityIdentifier == "reader.text.canvas"' in host,
         'host-production-engine-distinct-targets-and-stable-AX-lookup')
    need('not a SwiftUI update or FPS measurement' in host and
         all(t not in host for t in ('Thread.sleep', 'Task.sleep', 'Timer(', 'canvasDrawSequence', 'needsDisplay()', 'subviews[0]')),
         'no-fabricated-redraw-performance-or-private-layout-proof')
    return checks


def theme_protection(s, previous):
    b = json.loads(previous.read_text(encoding='utf-8'))
    assert b['kind'] == 'THEME_SUCCESSOR_BASELINE' and b['head'] == 'fd4b925192cf97f9afca459be703b1ac5510a10f', 'wrong-successor-baseline'
    assert b['existing'] == list(THEME_EXISTING) and b['new'] == list(THEME_NEW), 'successor-scope-drift'
    final = json.loads(Path(b['previous_final']).read_text(encoding='utf-8'))
    assert b['before'] == {p: d['sha256'] for p, d in final.items()}, 'not-the-frozen-nine-candidate-stage'
    old = {}
    for p, expected in b['before'].items():
        raw = (previous.parent / 'baseline' / p).read_bytes()
        assert hashlib.sha256(raw).hexdigest() == expected, 'successor-baseline-copy-drift:' + p
        old[p] = raw.decode('utf-8')
    def undo(text, new, original, label):
        assert text.count(new) == 1, 'successor-not-unique:' + label
        return text.replace(new, original, 1)
    restored = undo(s[VC], CACHE, '', 'nil-cache')
    restored = undo(restored, NEW_THEME, OLD_THEME, 'setTheme-only')
    assert restored == old[VC], 'outside-theme-cache-and-setTheme:' + VC
    p = EXISTING[3]
    restored = undo(s[p], THEME_INVENTORY_LINE, '', 'two-new-identities')
    restored = undo(restored, '"YueJingHostTests": 8,', '"YueJingHostTests": 6,', 'host-count')
    restored = undo(restored,
        'TOTAL = 144  # previous 142 selected + two Host theme-update regressions (one performance case excluded)',
        'TOTAL = 142  # previous 138 selected + four Host interruption regressions (one performance case excluded)', 'selected-count')
    assert restored == old[p], 'inventory-not-exact-two-identity-count-delta'
    p = EXISTING[4]
    restored = undo(s[p], "check(inventory.TOTAL == 144, 'reviewed-144-unique-cases')",
                    "check(inventory.TOTAL == 142, 'reviewed-142-unique-cases')", 'entry-count')
    assert restored == old[p], 'entry-successor-not-count-only'
    p = EXISTING[5]
    restored = undo(s[p], '== 144 and report["all_declared"] == 145', '== 142 and report["all_declared"] == 143', 'loader-count')
    restored = undo(restored, 'reviewed_144_selected_declarations', 'reviewed_142_selected_declarations', 'loader-label')
    assert restored == old[p], 'loader-successor-not-count-only'
    # Keep all historical source checks, negative controls, LEDGER and original phase intact.
    p = NEW[1]
    prefix, original_main = old[p].split('\ndef main():', 1)
    assert s[p].startswith(prefix), 'historical-checker-prefix-changed'
    main = s[p][s[p].index('\ndef main():'):]
    main = undo(main, THEME_ARGS, '', 'explicit-phase-args')
    main = undo(main, THEME_BRANCH, '', 'explicit-phase-branch')
    assert main == '\ndef main():' + original_main, 'historical-phase-rewritten'
    for table in (b['protected_tracked'], b['protected_extra']):
        for p, expected in table.items():
            raw = s[p].encode('utf-8') if p in s else (ROOT / p).read_bytes()
            assert hashlib.sha256(raw).hexdigest() == expected, 'successor-protected-hash-drift:' + p
    result = inventory.validate_source(ROOT)
    assert result['selected'] == 144 and result['all_declared'] == 145 and inventory.COUNTS['YueJingHostTests'] == 8, 'successor-inventory-count'
    assert 'YueJingHostTests' not in inventory.SWIFT_GROUPS and result['native_executions'] == 0
    return dict(selected=144, declared=145, host=8, previous_declared_preserved=143,
                protected_tracked=len(b['protected_tracked']), protected_extra=len(b['protected_extra']),
                protected_unique=len(set(b['protected_tracked']) | set(b['protected_extra'])),
                vc_restore='full bytes after exact cache/setTheme inverse; no method/file masking')


def theme_negatives(s, original, previous):
    rejected = []
    def reject(label, alt, check, expected=None):
        try: check(alt)
        except (AssertionError, ValueError) as error:
            if expected: assert str(error) == expected, (label, str(error))
            rejected.append(dict(name=label, by=str(error)))
        else: raise AssertionError('accepted-theme-negative:' + label)
    def change(p, old, new):
        assert old in s[p], 'theme-negative-not-applied:' + old
        alt = dict(s); alt[p] = s[p].replace(old, new)
        return alt
    pretheme = dict(s)
    pretheme[VC] = (previous.parent / 'baseline' / VC).read_bytes().decode('utf-8')
    reject('actual-pretheme-VC-semantic-not-freeze-rejection', pretheme, theme_contracts, 'same-theme-guard-before-container-work')
    mutations = [
        ('first-paper-skipped', VC, CACHE, '    private var appliedTheme: ReaderTheme? = .paper\n'),
        ('same-theme-still-loads', VC, 'guard appliedTheme != theme else { return false }\n        loadViewIfNeeded()', 'loadViewIfNeeded()\n        guard appliedTheme != theme else { return false }'),
        ('all-themes-return-false', VC, 'guard appliedTheme != theme else { return false }', 'return false'),
        ('changed-theme-not-applied', VC, 'view.backgroundColor = background; table.backgroundColor = background', '// no actual color application'),
        ('new-window-gated-by-theme-result', VIEWPORT, 'controller.setTheme(preferences.theme)', 'guard controller.setTheme(preferences.theme) else { return }'),
        ('callbacks-skipped-on-same-theme', VIEWPORT, 'controller.toolIntent = toolIntent; controller.onToolsInteraction = onToolsInteraction', '// callback skipped'),
        ('new-window-apply-skipped', VIEWPORT, 'controller.apply(window, userNavigation: navigation, restoring: navigation ? nil : handle.restoration(for: window.id))', '// no apply'),
        ('fake-host-without-real-color-check', THEME_HOST, '#expect(table.backgroundColor == theme.background)', '// fake color evidence'),
    ]
    for label, p, old, new in mutations: reject(label, change(p, old, new), theme_contracts)
    # Combined regressions cannot be excused by the optimization.
    alt = change(SCREEN, 'model.viewport.setInteractionActive(phase == .active)', '()')
    alt[VC] = alt[VC].replace('guard active, let value = touch, value.id == id, value.generation == generation else { return nil }', 'guard let value = touch else { return nil }')
    reject('optimization-with-scene-and-old-end-rollback', alt, source_contracts, 'synchronous-scene-interruption-bridge')
    guarded = lambda alt: theme_protection(alt, previous)
    for label, p, old, new in [
        ('out-of-setTheme-apply-drift', VC, 'restoring = true; userInputSinceRestore = false; window = value', 'restoring = true; window = value'),
        ('old-four-host-assertion-drift', HOST, 'controller.endToolTouch(old) == nil', 'controller.endToolTouch(old) == .toggle'),
        ('body-render-out-of-scope', CELL, 'setNeedsDisplay()', 'layoutIfNeeded()'),
        ('old-identity-drift', EXISTING[3], NAMES[0], NAMES[0] + 'Changed'),
        ('loader-path-guard-drift', EXISTING[5], 'Path(g["__file__"]).resolve() == ROOT / "scripts/validate_task3.py"', 'True'),
        ('historical-checker-assertion-drift', NEW[1], 'original-139-identities-changed', 'ignored-139-identities'),
    ]:
        reject(label, change(p, old, new), guarded)
    return rejected


def theme_main(original, previous):
    paths = (*EXISTING, *NEW, THEME_HOST, CELL)
    s = {p: (ROOT / p).read_bytes().decode('utf-8') for p in paths}
    recovery = source_contracts(s)
    recovery_negatives = negative_controls(s, original)
    checks = theme_contracts(s)
    protected = theme_protection(s, previous)
    negatives = theme_negatives(s, original, previous)
    print(json.dumps(dict(kind='OFFLINE_THEME_SUCCESSOR_NOT_SWIFT_OR_UIKIT',
        historical_phase='preserved; current 145/144 tree is not the historical 143/142 phase',
        recovery_source_checks=recovery, recovery_negative_controls=recovery_negatives,
        theme_source_checks=checks, theme_negative_controls=negatives, protection=protected,
        native_compilations=0, native_executions=0, performance_improvement='not measured; no root-cause claim'), indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--theme-update', action='store_true', help='Explicit same-theme successor; not the historical phase')
    parser.add_argument('--previous-stage', type=Path, help='Frozen nine-candidate baseline.json for the successor')
    args = parser.parse_args()
    if args.theme_update:
        if not args.previous_stage: parser.error('--theme-update requires --previous-stage')
        theme_main(args.baseline, args.previous_stage)
        return
    if args.previous_stage: parser.error('--previous-stage requires --theme-update')
    s = {p: (ROOT / p).read_text(encoding='utf-8') for p in (*EXISTING, HOST)}
    checks = source_contracts(s)
    protected = protection(s, args.baseline)
    negatives = negative_controls(s, args.baseline)
    print(json.dumps(dict(kind='OFFLINE_SOURCE_GUARDS_NOT_SWIFT_OR_UIKIT', source_checks=checks,
                          negative_controls=negatives, protection=protected,
                          native_executions=0, native_compilations=0, physical_acceptance='not performed'), indent=2))


if __name__ == '__main__':
    main()
