"""Offline source/negative-control checks, NOT Swift compilation or UI execution.
Use --baseline <this batch prebaseline.json> --snapshot-root <this batch snapshots>
for reproducible actual-worktree protection and exact business-code comparison.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

import check_navigation_panel_layout as lexical

ROOT = Path(__file__).resolve().parents[1]
CONTENT = 'App/ContentView.swift'
SCREEN = 'App/Reading/ReaderScreen.swift'
DOCK = 'App/Reading/ReaderFloatingToolsView.swift'
LAYOUT = 'App/Library/LibraryLayout.swift'
METRICS = 'App/Reading/ReaderToolAppearance.swift'
VISIBILITY = 'App/Reading/ReaderToolVisibility.swift'
EXISTING = [CONTENT, SCREEN, DOCK]
NEW = ['scripts/check_reader_dock_schemes.py', 'docs/READER_DOCK_SCHEMES_LOCAL.md']


def member(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


def source_contracts(sources):
    c, s, d, layout, metrics, visibility = (sources[p] for p in (CONTENT, SCREEN, DOCK, LAYOUT, METRICS, VISIBILITY))
    checks = []
    def need(ok, name):
        if not ok:
            raise AssertionError(name)
        checks.append(name)
    for path in EXISTING:
        lexical.check_balanced_delimiters(path, lexical.strip_swift_comments_and_strings(sources[path]))
    need(True, 'three-modified-swift-delimiters')
    need('ReaderScreen(model: route.model, routeID: route.id, layout: layout) { readerRoutes.finishExit(route.id) }' in c
         and '.id(route.id)' in c and 'LibraryLayout.restored(from: libraryLayoutRawValue)' in c,
         'single-original-reader-cover-pass-restored-management-value')
    need('let layout: LibraryLayout' in s and 'let layout: LibraryLayout' in d and
         'appearance: appearance, layout: layout,' in s and 'open: openPanel, focusedControl: $focusedControl)' in s,
         'read-only-layout-through-screen-to-dock')
    need(re.findall(r'case (\w+) = "(\w+)"', layout) == [('direct', 'a'), ('tabs', 'b'), ('sidebar', 'c')]
         and 'defaultLayout: LibraryLayout = .tabs' in layout and 'LibraryLayout(rawValue: rawValue) ?? defaultLayout' in layout,
         'existing-abc-map-b-default-fallback-unchanged')
    need('switch layout {\n            case .direct: floatingCapsule\n            case .tabs: edgeBar\n            case .sidebar: edgeDock\n            }' in d,
         'three-distinct-dock-layout-branches')
    need(not any(x in s + d for x in ('@AppStorage', 'UserDefaults', 'AppAppearance', 'LibraryService', '@StateObject',
                                      'preferredColorScheme', 'TabView', 'NavigationStack', 'onTapGesture', 'DragGesture', 'withAnimation',
                                      'safeAreaInset', 'safeAreaPadding', 'safeAreaBar', 'Timer', 'asyncAfter', 'URLSession',
                                      '@Observable', 'import Observation', 'import SwiftData')),
         'no-persistence-owner-theme-leak-viewport-inset-gesture-or-new-platform-api')
    need(re.findall(r'@State\s+private var (\w+)\s*=', d) == ['trayExpanded'] and
         '@State private var trayExpanded = false' in d and 'Task {' not in d and '.task' not in d,
         'only-new-state-is-local-default-collapsed-ui-bool-no-task')
    need('private var visible: Bool { state.visible && state.panel == nil }' in d and
         '.allowsHitTesting(visible && state.canInteract).accessibilityHidden(!visible)' in d,
         'hidden-and-panel-dock-hit-and-ax-gates')
    need('.modifier(ReaderToolVisibility(visible: visible, hiddenOffset: ReaderMotion.hiddenTravel, reduceMotion: reduceMotion))' in d and
         '.animation(' not in d and '.transaction { transaction in transaction.animation = nil }' in visibility and
         '.animation(reduceMotion ? nil : ReaderMotion.toolVisibility,' in visibility,
         'existing-visibility-only-animation-and-reduce-motion-isolation')
    need('toolButton("目录", symbol: "list.bullet", panel: .directory, key: "directory")\n'
         '            .disabled(model.chapterTotal == 0 || model.exitSaveFailed || !state.canInteract)' in d and
         'toolButton("排版", symbol: "textformat.size", panel: .settings, key: "settings")\n'
         '            .disabled(model.window == nil || model.exitSaveFailed || !state.canInteract)' in d,
         'original-tool-actions-keys-and-disabled-predicates')
    need('Button { open(panel) } label:' in d and '.accessibilityIdentifier("reader.tools.\\(key)")' in d and
         '.accessibilityFocused($focusedControl, equals: key)' in d and
         '.frame(maxWidth: .infinity, minHeight: metrics.controlHeight)' in d and
         'controlHeight = compactHeight ? 44 : max(44, scaledControl)' in metrics,
         'original-action-focus-identifiers-and-scaled-44pt-tools')
    a = member(d, '    private var floatingCapsule:', '    private var edgeBar:')
    b = member(d, '    private var edgeBar:', '    private var edgeDock:')
    edge = member(d, '    private var edgeDock:', '    private var collapseButton:')
    collapse = member(d, '    private var collapseButton:', '    private var directoryButton:')
    need('HStack(spacing: 4) { directoryButton; settingsButton }' in a and
         'RoundedRectangle(cornerRadius: 28' in a and '.frame(maxWidth: metrics.verticalButtons ? 280 : 340)' in a,
         'a-floating-bounded-two-tool-capsule')
    need('directoryButton.fixedSize(horizontal: true, vertical: false)\n'
         '                        Spacer(minLength: 24).accessibilityHidden(true)\n'
         '                        settingsButton.fixedSize(horizontal: true, vertical: false)' in b and
         'Text(' not in b and 'Label(' not in b and 'model.' not in b and '.frame(maxWidth: .infinity)' in b,
         'b-actual-empty-center-no-chapter-progress-or-query')
    need('.padding(.horizontal, layout == .tabs ? 0 : 16).padding(.bottom, layout == .tabs ? 0 : 8)' in s and
         '.ignoresSafeArea' not in d and 'Rectangle().fill(appearance.edge).frame(height: 0.5).allowsHitTesting(false)' in b,
         'b-safe-area-edge-bar-only-dock-margins-changed')
    need('if trayExpanded {' in edge and
         'HStack(spacing: 4) { directoryButton; settingsButton; collapseButton }' in edge and
         'VStack(spacing: 4) { directoryButton; settingsButton; collapseButton }' in edge and
         'Label("阅读工具", systemImage: "slider.horizontal.3")' in edge and
         '.frame(maxWidth: .infinity, alignment: .trailing)' in edge and 'trayExpanded = true' in edge,
         'c-trailing-capsule-expands-real-tools-and-clear-collapse')
    need('guard visible, state.canInteract, !model.exitSaveFailed else { return }' in edge and
         'guard visible, state.canInteract, !model.exitSaveFailed else { return }' in collapse and
         '.disabled(model.exitSaveFailed || !state.canInteract)' in edge and
         '.disabled(model.exitSaveFailed || !state.canInteract)' in collapse,
         'c-toggle-actions-and-controls-respect-busy-state')
    need('restoreFocus(to: model.chapterTotal > 0 ? "directory" : (model.window != nil ? "settings" : "dock.collapse"))' in edge and
         'trayExpanded = false\n            restoreFocus(to: "dock.expand")' in collapse and
         '.accessibilityIdentifier("reader.tools.expand")' in edge and
         '.accessibilityIdentifier("reader.tools.collapse")' in collapse and
         '.frame(minWidth: 44, minHeight: metrics.controlHeight)' in edge + collapse,
         'c-expand-available-focus-and-collapse-focus-return-44pt-ax')
    need('.onChange(of: layout) { _ in\n            trayExpanded = false' in d and
         '.onChange(of: visible)' not in d and '.onChange(of: state' not in d and 'onDisappear' not in d and
         d.count('trayExpanded = false') == 3 and d.count('trayExpanded = true') == 1,
         'c-reset-only-initial-layout-change-manual-collapse-hide-panel-preserve-state')
    need(d.count('ViewThatFits(in: .horizontal)') == 3 and 'if metrics.verticalButtons { verticalPair }' in a + b and
         'ScrollView(.vertical)' in edge and 'VStack(spacing: 4) { directoryButton; settingsButton }' in d and
         'metrics.compactHeight ? 88 : 220, metrics.controlHeight * 3 + 8' in edge,
         'width-fallbacks-and-bounded-scroll-for-large-font-short-height')
    need('.overlay' not in d and d.count('.stroke(appearance.edge, lineWidth: 0.5).allowsHitTesting(false)') == 3,
         'dock-decoration-is-noninteractive-background-not-foreground-hit-cover')
    header = member(s, '    private func titleBar(', '    private var panelPresentation:')
    stroke = '.background { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(appearance.edge, lineWidth: 0.5) }'
    fill = '.background(appearance.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))'
    need(stroke in header and fill in header and header.index(stroke) < header.index(fill) and
         'Button { exitReader() }' in header and '.accessibilityIdentifier("reader.exit")' in header and
         '.frame(minWidth: 44, minHeight: 44)' in header and
         '.allowsHitTesting(visible && tools.canInteract).accessibilityHidden(!visible)' in header,
         'exit-header-original-action-hit-region-id-and-stroke-before-fill')
    return checks


def d1_focus_contracts(sources):
    """Bind both ends of the D1 repair; do not mistake current focus for restore memory."""
    s, d = sources[SCREEN], sources[DOCK]
    checks = []
    def need(ok, name):
        if not ok:
            raise AssertionError(name)
        checks.append(name)
    need('rememberFocus: { lastPanelControl = $0 }' in s and
         'let rememberFocus: @MainActor (String) -> Void' in d,
         'D1-parent-restore-memory-callback-wired')
    need('    private func restoreFocus(to target: String) {\n'
         '        rememberFocus(target)\n        focusedControl = target\n    }' in d and
         'trayExpanded = false\n            restoreFocus(to: "dock.expand")' in d,
         'D1-manual-collapse-synchronizes-memory-and-current-expand-focus')
    need('restoreFocus(to: model.chapterTotal > 0 ? "directory" : (model.window != nil ? "settings" : "dock.collapse"))' in d and
         'trayExpanded = false\n            rememberFocus(layout == .sidebar ? "dock.expand" : "back")' in d,
         'D1-reexpand-and-layout-reset-remember-only-mounted-targets')
    need('lastPanelControl = panel == .directory ? "directory" : "settings"' in s and
         'focusedControl = lastPanelControl ?? "back"' in s and
         '.onChange(of: visible)' not in d and '.onChange(of: state' not in d,
         'D1-expanded-panel-return-and-original-reveal-consumer-preserved')
    return checks


def d1_focus_specifications(sources):
    """Six bounded source-derived specification rows, NOT a Swift state-machine run."""
    d1_focus_contracts(sources)
    s, d = sources[SCREEN], sources[DOCK]
    collapse = member(d, '    private var collapseButton:', '    private func restoreFocus(')
    collapsed_target = re.search(r'restoreFocus\(to: "([^"]+)"\)', collapse).group(1)
    panel_targets = re.search(r'lastPanelControl = panel == \.directory \? "([^"]+)" : "([^"]+)"', s).groups()
    expanded_target = re.search(r'restoreFocus\(to: model.chapterTotal > 0 \? "([^"]+)"', d).group(1)
    rows = []
    for panel, panel_target in zip(('directory', 'settings'), panel_targets):
        # Both tools available in these rows; the source contract checks other availability gates.
        for action, target, mounted, expected in (
            ('panel-close -> hide/show', panel_target, {'back', 'directory', 'settings', 'dock.collapse'}, panel),
            ('panel-close -> manual-collapse -> hide/show', collapsed_target, {'back', 'dock.expand'}, 'dock.expand'),
            ('panel-close -> manual-collapse -> reexpand -> hide/show', expanded_target,
             {'back', 'directory', 'settings', 'dock.collapse'}, 'directory'),
        ):
            assert target == expected and target in mounted, 'D1 source-derived specification: ' + panel + '/' + action
            rows.append(dict(panel=panel, sequence='open ' + panel + ' -> ' + action,
                             remembered_target=target, expected=expected, target_is_mounted=True))
    return rows


def compare_snapshots(sources, root):
    old = {p: (root / p).read_text(encoding='utf8') for p in EXISTING}
    c = sources[CONTENT].replace('ReaderScreen(model: route.model, routeID: route.id, layout: layout)',
                                 'ReaderScreen(model: route.model, routeID: route.id)')
    assert c == old[CONTENT], 'ContentView changed outside the single read-only cover argument'
    s = sources[SCREEN].replace('    let layout: LibraryLayout\n', '')
    s = s.replace('appearance: appearance, layout: layout, rememberFocus: { lastPanelControl = $0 },\n'
                  '                        open: openPanel, focusedControl: $focusedControl)',
                  'appearance: appearance, layout: layout, open: openPanel, focusedControl: $focusedControl)')
    s = s.replace('appearance: appearance, layout: layout, open: openPanel, focusedControl: $focusedControl)',
                  'appearance: appearance, open: openPanel, focusedControl: $focusedControl)')
    s = s.replace('.padding(.horizontal, layout == .tabs ? 0 : 16).padding(.bottom, layout == .tabs ? 0 : 8)',
                  '.padding(.horizontal, 16).padding(.bottom, 8)')
    assert s == old[SCREEN], 'ReaderScreen changed outside layout input, dock focus callback and dock margins'
    begin = '    private var directoryButton:'
    assert sources[DOCK][sources[DOCK].index(begin):] == old[DOCK][old[DOCK].index(begin):], 'Original button/action/disabled/AX/font implementation drift'
    for p in EXISTING:
        assert sources[p].count('    let layout: LibraryLayout') == (0 if p == CONTENT else 1)
    return ['ContentView complete equality after single argument reversal',
            'ReaderScreen complete equality after exact layout/focus-callback/dock-margin reversals (all header/viewport/exit/save/task/DEBUG code)',
            'Dock original directory/settings/toolButton complete tail equality']


def digest(path):
    h = hashlib.sha256(); size = 0
    with path.open('rb') as handle:
        while chunk := handle.read(131072):
            h.update(chunk); size += len(chunk)
    return dict(bytes=size, sha256=h.hexdigest())


def protection(baseline_path, snapshot_root, sources):
    base = json.loads(baseline_path.read_text(encoding='utf8'))
    assert base['existing'] == EXISTING and base['new'] == NEW, 'Wrong batch whitelist'
    for p in EXISTING:
        assert digest(snapshot_root/p) == base['files'][p], 'Snapshot is not actual pre-edit bytes: ' + p
    changed = [p for p,h in base['files'].items() if digest(ROOT/p) != h]
    assert set(changed) == set(EXISTING), 'Unexpected changed/missing files: ' + str(changed)
    env = {**os.environ, 'GIT_OPTIONAL_LOCKS': '0'}
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=ROOT, env=env).decode('utf8')
    assert git('rev-parse', 'HEAD').strip() == base['head'] and digest(ROOT/'.git/index') == base['index'], 'HEAD/index changed'
    assert not git('diff', '--cached', '--binary'), 'Staged changes'
    expected = set(base['status'].splitlines()) | {' M '+p for p in EXISTING} | {'?? '+p for p in NEW if (ROOT/p).exists()}
    assert set(git('status', '--short').splitlines()) == expected, 'Unexpected git status delta'
    before = set(base['groups']['existing_script_pycache'])
    after = {p.relative_to(ROOT).as_posix() for p in (ROOT/'scripts/__pycache__').rglob('*') if p.is_file()}
    assert before == after, 'Script bytecode path delta'
    return dict(frozen_unique=len(base['files']), expected_changed=changed,
                protected_unchanged=len(base['files'])-len(changed), head_index_staged_unchanged=True,
                groups={k: dict(total=len(v), unchanged=sum(p not in changed for p in v)) for k,v in base['groups'].items()},
                exact_snapshot_comparisons=compare_snapshots(sources, snapshot_root))


def negative_controls(sources, snapshots):
    controls = [
        ('swapped-layout-mapping', DOCK, 'case .direct: floatingCapsule', 'case .direct: edgeBar'),
        ('wrong-default', LAYOUT, 'defaultLayout: LibraryLayout = .tabs', 'defaultLayout: LibraryLayout = .direct'),
        ('lost-propagation', CONTENT, 'routeID: route.id, layout: layout)', 'routeID: route.id)'),
        ('lost-directory', DOCK, 'toolButton("目录",', 'toolButton("书架",'),
        ('lost-disabled-condition', DOCK, 'model.chapterTotal == 0 || ', ''),
        ('lost-tool-id', DOCK, 'reader.tools.\\(key)', 'reader.wrong.\\(key)'),
        ('hidden-dock-hit-leak', DOCK, '.allowsHitTesting(visible && state.canInteract)', '.allowsHitTesting(true)'),
        ('hidden-dock-ax-leak', DOCK, '.accessibilityHidden(!visible)', '.accessibilityHidden(false)'),
        ('app-theme-coupling', DOCK, 'let layout: LibraryLayout', 'let appAppearance: AppAppearance\n    let layout: LibraryLayout'),
        ('new-persistence', DOCK, '@State private var trayExpanded', '@AppStorage("dock") private var trayExpanded'),
        ('foreground-hit-cover', DOCK, '.background {', '.overlay {'),
        ('hidden-resets-c-focus-target', DOCK, '.onChange(of: layout)', '.onChange(of: visible)'),
        ('c-not-collapsed-initially', DOCK, '@State private var trayExpanded = false', '@State private var trayExpanded = true'),
        ('fake-b-chapter', DOCK, 'Spacer(minLength: 24).accessibilityHidden(true)', 'Text("第 1 章")'),
        ('below-44pt-metrics', METRICS, 'compactHeight ? 44 : max(44, scaledControl)', 'compactHeight ? 32 : max(32, scaledControl)'),
        ('D1-missing-parent-sync', SCREEN, 'rememberFocus: { lastPanelControl = $0 }', 'rememberFocus: { _ in }'),
        ('D1-wrong-parent-map', SCREEN, 'rememberFocus: { lastPanelControl = $0 }', 'rememberFocus: { _ in lastPanelControl = "settings" }'),
        ('D1-missing-child-sync', DOCK, '        rememberFocus(target)\n', ''),
        ('D1-wrong-collapse-target', DOCK, 'restoreFocus(to: "dock.expand")', 'restoreFocus(to: "settings")'),
        ('D1-reexpand-stale-target', DOCK, 'restoreFocus(to: model.chapterTotal > 0 ?', 'focusedControl = model.chapterTotal > 0 ?'),
        ('D1-lost-panel-return', SCREEN, 'lastPanelControl = panel == .directory ? "directory" : "settings"', 'lastPanelControl = "dock.expand"'),
        ('D1-layout-reset-stale-target', DOCK, '            rememberFocus(layout == .sidebar ? "dock.expand" : "back")\n', ''),
    ]
    rejected = []
    for name, path, before, after in controls:
        assert before in sources[path], 'Negative control not bound: ' + name
        altered = dict(sources); altered[path] = altered[path].replace(before, after, 1)
        try:
            source_contracts(altered)
            d1_focus_contracts(altered)
        except (AssertionError, ValueError):
            rejected.append(name)
        else:
            raise AssertionError('Accepted negative control: ' + name)
    # Exact snapshot comparisons must reject real business and hit-order changes, not only tokens.
    if snapshots:
        for name, before, after in [
            ('exit-save-changed', 'succeeded = await model.close()', 'succeeded = true'),
            ('viewport-hook-changed', 'onAnchor: model.visibleChanged', 'onAnchor: model.scrollingEnded'),
            ('exit-stroke-fill-reversed',
             '        .background { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(appearance.edge, lineWidth: 0.5) }\n'
             '        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))',
             '        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))\n'
             '        .background { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(appearance.edge, lineWidth: 0.5) }'),
        ]:
            assert before in sources[SCREEN], name
            altered = dict(sources); altered[SCREEN] = altered[SCREEN].replace(before, after, 1)
            try:
                compare_snapshots(altered, snapshots)
            except AssertionError:
                rejected.append(name)
            else:
                raise AssertionError('Accepted snapshot negative control: ' + name)
    return rejected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, help='Actual pre-edit freeze, NOT an old batch')
    parser.add_argument('--snapshot-root', type=Path, help='Three complete pre-edit copies')
    args = parser.parse_args()
    if bool(args.baseline) != bool(args.snapshot_root):
        parser.error('--baseline and --snapshot-root must be supplied together')
    paths = EXISTING + [LAYOUT, METRICS, VISIBILITY]
    sources = {p: (ROOT/p).read_text(encoding='utf8') for p in paths}
    d1_checks = d1_focus_contracts(sources)
    checks = source_contracts(sources) + d1_checks
    specifications = d1_focus_specifications(sources)
    controls = negative_controls(sources, args.snapshot_root)
    print(json.dumps(dict(kind='OFFLINE_SOURCE_AND_HASH_NOT_SWIFT_OR_UI_EXECUTION', source_checks=len(checks), checks=checks,
        negative_controls_rejected=controls,
        d1_source_contracts=len(d1_checks), d1_bounded_specification_rows=specifications,
        c_state_semantics='initial false; user expands/collapses; hide/panel preserves; layout change resets; route destruction discards',
        protection=protection(args.baseline, args.snapshot_root, sources) if args.baseline else 'not requested',
        native_compilations=0, native_executions=0, native_touch_tests=0, fps_measurements=0), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
