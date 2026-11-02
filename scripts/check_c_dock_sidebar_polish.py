"""Exact-preimage local checks. Not Swift compilation, native tests or FPS measurement."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

import check_navigation_panel_layout as lexical

ROOT = Path(__file__).resolve().parents[1]
DOCK = 'App/Reading/ReaderFloatingToolsView.swift'
SCREEN = 'App/Reading/ReaderScreen.swift'
VC = 'App/Reading/ReaderViewController.swift'
CONTENT = 'App/ContentView.swift'
SHELL = 'App/Library/LibraryNavigationShell.swift'
SIDEBAR = 'App/Library/LibrarySidebarView.swift'
EXISTING = (DOCK, SCREEN, VC, CONTENT, SHELL)
ALLOWED = (*EXISTING, SIDEBAR, 'scripts/check_c_dock_sidebar_polish.py', 'docs/C_DOCK_SIDEBAR_POLISH.md')


def require(ok, label):
    if not ok:
        raise ValueError(label)


def fingerprint(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for data in iter(lambda: f.read(1048576), b''):
            h.update(data)
    return dict(bytes=path.stat().st_size, sha256=h.hexdigest())


def swap(text, before, after, count=1):
    require(text.count(before) == count, 'preimage-occurrences:' + repr(before[:80]))
    return text.replace(before, after)


def expected_sources(old):
    expected = {}
    d = swap(old[DOCK], '    @ObservedObject var model: ReaderViewModel\n', '')
    d = swap(d, '    let appearance: ReaderToolAppearance\n', '    let appearance: ReaderToolAppearance\n'
             '    let directoryAvailable: Bool\n    let settingsAvailable: Bool\n    let exitSaveFailed: Bool\n')
    for before, after, count in (
        ('model.chapterTotal > 0', 'directoryAvailable', 1),
        ('model.chapterTotal == 0', '!directoryAvailable', 1),
        ('model.window != nil', 'settingsAvailable', 1),
        ('model.window == nil', '!settingsAvailable', 1),
        ('model.exitSaveFailed', 'exitSaveFailed', 7),
    ):
        d = swap(d, before, after, count)
    for before in ('            .opacity(trayExpanded ? 1 : 0)\n', '            .opacity(trayExpanded ? 0 : 1)\n'):
        d = swap(d, before, '            .transaction { $0.animation = nil }\n' + before)
    for before in ('            .accessibilityHidden(!trayExpanded || !visible)\n', '            .accessibilityHidden(trayExpanded || !visible)\n'):
        d = swap(d, before, before + '            .animation(reduceMotion ? nil : ReaderMotion.toolVisibility, value: trayExpanded)\n')
    d = swap(d, '\n        .transaction { $0.animation = nil }\n', '\n')
    d = swap(d,
        '        // Both control groups retain their structural identity and bottom-right anchor.\n'
        '        // Expansion does not mount a branch or start a second presentation animation.\n'
        '        // Only the active group participates in hit testing and accessibility.\n'
        '        // The existing outer visibility modifier still owns whole-tool reveal/hide.\n',
        '        // Stable control groups keep their bottom-right anchor and existing actions.\n'
        '        // Only the two group opacity values animate; child text and layout do not.\n'
        '        // Model publication is observed by ReaderScreen, not subscribed to again here.\n'
        '        // Whole-tool reveal/hide remains owned by the existing visibility modifier.\n')
    expected[DOCK] = d
    expected[SCREEN] = swap(old[SCREEN],
        '                    ReaderFloatingToolsView(model: model, state: tools, metrics: metrics,\n'
        '                        appearance: appearance, rememberFocus: { lastPanelControl = $0 },\n',
        '                    ReaderFloatingToolsView(state: tools, metrics: metrics, appearance: appearance,\n'
        '                        directoryAvailable: model.chapterTotal > 0, settingsAvailable: model.window != nil,\n'
        '                        exitSaveFailed: model.exitSaveFailed, rememberFocus: { lastPanelControl = $0 },\n')
    v = swap(old[VC], '        label?.text = [\n', '        guard let label else { return }\n        let next = [\n')
    expected[VC] = swap(v,
        '        ].joined(separator: "\\n")\n    }\n}\n// END READER DIAGNOSTICS recorder',
        '        ].joined(separator: "\\n")\n'
        '        // Several observations can describe the same facts in one touch chain.\n'
        '        // Preserve every recorded event, but avoid invalidating UILabel for equal text.\n'
        '        guard label.text != next else { return }\n'
        '        label.text = next\n    }\n}\n// END READER DIAGNOSTICS recorder')
    c = swap(old[CONTENT], '    @Environment(\\.colorScheme) private var colorScheme\n',
             '    @Environment(\\.colorScheme) private var colorScheme\n'
             '    @AccessibilityFocusState private var focusedLibraryControl: String?\n')
    c = swap(c,
        '                canNavigate: canNavigateManagement, appearance: appearance,\n'
        '                onDrawerSection: selectDrawerSection, onDrawerInformation: openDrawerInformation,\n',
        '                canNavigate: canNavigateManagement, appearance: appearance, focusedControl: $focusedLibraryControl,\n')
    expected[CONTENT] = swap(c, '        .accessibilityIdentifier("library.screen")\n',
        '        .overlay(alignment: .leading) {\n'
        '            LibrarySidebarView(section: selectedSection, presented: drawerPresentation,\n'
        '                canNavigate: canNavigateManagement, appearance: appearance,\n'
        '                onSection: selectDrawerSection, onInformation: openDrawerInformation,\n'
        '                focusedControl: $focusedLibraryControl)\n'
        '        }\n'
        '        .onChange(of: drawerPresented) { open in\n'
        '            focusedLibraryControl = open ? "library.close" : "library.menu"\n'
        '        }\n'
        '        .accessibilityIdentifier("library.screen")\n')
    s = swap(old[SHELL], '    let onDrawerSection: (LibrarySection) -> Void\n'
             '    let onDrawerInformation: (LibraryInformationPage) -> Void\n',
             '    @AccessibilityFocusState.Binding var focusedControl: String?\n')
    s = swap(s, '    @Environment(\\.accessibilityReduceMotion) private var reduceMotion\n'
             '    @AccessibilityFocusState private var focusedControl: Focus?\n'
             '    private enum Focus: Hashable { case menu, close }\n', '')
    s = swap(s,
        '        ZStack(alignment: .leading) {\n'
        '            rootContent\n                .allowsHitTesting(!drawerPresented)\n'
        '                .accessibilityHidden(drawerPresented)\n            drawerLayer\n        }\n',
        '        rootContent\n            .allowsHitTesting(!drawerPresented)\n            .accessibilityHidden(drawerPresented)\n')
    s = swap(s, '.accessibilityFocused($focusedControl, equals: .menu)', '.accessibilityFocused($focusedControl, equals: "library.menu")')
    s = swap(s, '        .onChange(of: drawerPresented) { open in focusedControl = open ? .close : .menu }\n', '')
    marker = '    private var drawerLayer: some View {\n'
    require(s.count(marker) == 1 and s.endswith('}\n'), 'unique-old-drawer')
    expected[SHELL] = s[:s.index(marker)] + '}\n'
    return expected


def contracts(src, expected):
    checks = []
    def need(ok, name):
        require(ok, name)
        checks.append(name)
    for name in EXISTING:
        need(src[name] == expected[name], 'exact-reviewed-delta:' + name)
    for name in (*EXISTING, SIDEBAR):
        lexical.check_balanced_delimiters(name, lexical.strip_swift_comments_and_strings(src[name]))
        checks.append('lexical-delimiters:' + name)
    d, r, v, c, shell, side = (src[n] for n in (*EXISTING, SIDEBAR))
    need('@ObservedObject' not in d and 'ReaderViewModel' not in d, 'dock-no-second-broad-model-subscription')
    need(d.count('.animation(reduceMotion ? nil : ReaderMotion.toolVisibility, value: trayExpanded)') == 2 and
         d.count('.transaction { $0.animation = nil }') == 2, 'two-local-opacity-scopes-child-layout-not-animated')
    need('ViewThatFits(in: .horizontal)' in d and 'ScrollView(.vertical)' in d and
         'metrics.controlHeight * 3 + 8' in d, 'existing-large-font-adaptive-fallback-retained')
    need('visible && state.canInteract' in d and 'guard visible, state.canInteract, !exitSaveFailed' in d and
         '.allowsHitTesting(!trayExpanded && visible && state.canInteract)' in d,
         'dock-interaction-save-failure-and-inactive-group-gates')
    need('ReaderToolVisibility(visible: visible' in d and 'model.preferences.theme' in r and
         '.padding(.horizontal, 16).padding(.bottom, 8)' in r, 'existing-whole-tool-animation-theme-and-overlay-geometry')
    need('guard label.text != next else { return }\n        label.text = next' in v,
         'exact-equal-text-does-not-write-UILabel')
    need(c.count('NavigationStack {') == 1 and c.count('LibrarySidebarView(') == 1 and
         c.index('LibrarySidebarView(') > c.index('.navigationDestination(isPresented: informationPresentation)'),
         'sidebar-overlay-above-existing-stack-not-in-shelf-content')
    need('drawerLayer' not in shell and 'LibrarySidebarView' not in shell, 'old-content-only-drawer-removed')
    need('rootContent\n            .allowsHitTesting(!drawerPresented)\n            .accessibilityHidden(drawerPresented)' in shell,
         'underlying-content-hit-and-accessibility-isolation')
    need('open ? "library.close" : "library.menu"' in c and 'equals: "library.menu"' in shell and
         'equals: "library.close"' in side, 'single-parent-accessibility-focus-transfer')
    need('let width = min(304, max(0, proxy.size.width - 64))' in side and
         '.frame(width: width, height: proxy.size.height)' in side,
         'sidebar-304-cap-and-minimum-64-close-strip')
    need('Color.black.opacity(0.24).ignoresSafeArea()' in side and
         'appearance.surface.ignoresSafeArea(.container, edges: .vertical)' in side,
         'full-navigation-scrim-and-continuous-safe-area-surface')
    need('ScrollView {' in side and '.fixedSize(horizontal: false, vertical: true)' in side and
         '.font(.headline)' in side and 'Text("阅境 · 工作区")' not in side,
         'scrollable-dynamic-type-compact-header-no-oversized-workspace-title')
    need('.keyboardShortcut(.cancelAction)' in side and '.accessibilityAction(.escape)' in side and
         '.allowsHitTesting(presented)' in side and side.count('presented = false') == 3,
         'close-button-scrim-escape-and-closed-overlay-pass-through')
    need('ForEach(LibrarySection.allCases, id: \\.self)' in side and 'onSection(item)' in side and
         'onInformation(page)' in side and side.count('.disabled(!canNavigate)') == 2 and
         'page: .diagnostics' in side and 'page: .license' in side,
         'all-current-sections-information-actions-and-busy-gates')
    need('reduceMotion ? nil : .easeOut(duration: 0.15)' in side and
         'if reduceMotion { $0.animation = nil }' in side, 'drawer-reduced-motion-no-delay')
    need(not re.search(r'@StateObject|@AppStorage|LibraryViewModel|LibraryService|ReaderRouteOwner|Task\s*\{|\.task\s*\{|Timer|URLSession|UserDefaults|NotificationCenter|withAnimation|\.blur\(|\.scaleEffect\(|\.zIndex\(|DragGesture', side),
         'sidebar-presentation-only-no-owner-work-timer-blur-scale-or-global-gesture')
    need(not re.search(r'\bLibraryLayout\b|\bTabView\b|\bfloatingCapsule\b|\bedgeBar\b|\bchooseLayout\b|libraryLayoutRawValue|dev\.yuejing\.ui\.libraryLayout\.v1', d + c + shell + side), 'only-C-no-layout-selector-or-alternatives')
    return checks


def negative_checks(src, expected):
    mutations = [
        (DOCK, '    let state:', '    @ObservedObject var model: ReaderViewModel\n    let state:'),
        (DOCK, '.animation(reduceMotion ? nil : ReaderMotion.toolVisibility, value: trayExpanded)', '.animation(nil, value: trayExpanded)'),
        (DOCK, '.allowsHitTesting(!trayExpanded && visible && state.canInteract)', '.allowsHitTesting(true)'),
        (DOCK, 'ReaderToolVisibility(visible: visible', 'ReaderToolVisibility(visible: true'),
        (SCREEN, 'exitSaveFailed: model.exitSaveFailed', 'exitSaveFailed: false'),
        (VC, 'guard label.text != next else { return }', '// guard removed'),
        (VC, 'toolsTap.cancelsTouchesInView = false', 'toolsTap.cancelsTouchesInView = true'),
        (CONTENT, '.id(route.id)', '.id(UUID())'),
        (CONTENT, 'guard canChangeManagement else { return }', 'guard true else { return }'),
        (SHELL, '.allowsHitTesting(!drawerPresented)', '.allowsHitTesting(true)'),
        (SIDEBAR, 'min(304, max(0, proxy.size.width - 64))', 'proxy.size.width'),
        (SIDEBAR, '.allowsHitTesting(presented)', '.allowsHitTesting(true)'),
        (SIDEBAR, '.accessibilityAction(.escape)', '.accessibilityAction(named: Text("none"))'),
        (SIDEBAR, 'ScrollView {', 'VStack {'),
        (SIDEBAR, 'if reduceMotion { $0.animation = nil }', 'if false { $0.animation = nil }'),
        (SIDEBAR, '    var body: some View {', '    var body: some View {\n        Task { }'),
    ]
    for n, (path, before, after) in enumerate(mutations, 1):
        require(before in src[path], 'negative-control-marker:' + str(n))
        bad = dict(src)
        bad[path] = bad[path].replace(before, after, 1)
        try:
            contracts(bad, expected)
        except (ValueError, AssertionError):
            continue
        raise ValueError('negative-control-accepted:' + str(n))
    return len(mutations)


def git(*args):
    result = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, timeout=90,
                            env=dict(os.environ, GIT_OPTIONAL_LOCKS='0'))
    require(result.returncode == 0, 'git-failed:' + repr(args) + ':' + result.stderr.decode('utf-8', 'replace'))
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--self-check', action='store_true')
    args = parser.parse_args()
    base = args.baseline.resolve()
    require(base.is_relative_to(ROOT / 'artifacts'), 'baseline-not-in-project-artifacts')
    state = json.loads((base / 'baseline.json').read_bytes())
    require(state['allowed'] == list(ALLOWED), 'baseline-scope')
    for name in EXISTING:
        require(fingerprint(base / 'preimage' / name) == state['preimage'][name], 'preimage-hash:' + name)
    old = {n: (base / 'preimage' / n).read_text(encoding='utf-8') for n in EXISTING}
    src = {n: (ROOT / n).read_text(encoding='utf-8') for n in (*EXISTING, SIDEBAR)}
    expected = expected_sources(old)
    checks = contracts(src, expected)
    negatives = negative_checks(src, expected) if args.self_check else 0
    geometry = []
    for width in (0, 32, 64, 120, 240, 320, 375, 390, 428, 667, 844, 1024):
        panel = min(304, max(0, width - 64))
        require(0 <= panel <= min(304, width), 'width-bounds')
        require(width < 64 or width - panel >= 64, 'close-strip-width')
        geometry.append(dict(width=width, panel=panel, remaining=width-panel))
    require(git('rev-parse', 'HEAD').decode().strip() == state['head'], 'head-drift')
    require(fingerprint(ROOT / '.git/index') == state['index'], 'index-drift')
    require(not git('diff', '--cached', '--name-only'), 'unexpected-staging')
    require(set(git('diff', '--name-only').decode().splitlines()) == set(EXISTING), 'tracked-changed-paths')
    require(not git('diff', '--check'), 'diff-whitespace')
    untracked = set(git('ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')) - {''}
    require(untracked == set(ALLOWED[5:]) | {'.architect_memory.json', 'PROJECT_STATE.md', 'ask_architect.py'}, 'untracked-paths')
    protection = json.loads((base / 'protection-baseline.json').read_bytes())
    drift = []
    for name, value in protection.items():
        p = Path(name) if Path(name).is_absolute() else ROOT / name
        if not p.is_file() or fingerprint(p) != value:
            drift.append(name)
    require(not drift, 'outside-scope-drift:' + repr(drift))
    print(json.dumps(dict(passed=True,contracts=checks,contract_count=len(checks),negative_controls=negatives,
                         synthetic_width_checks=geometry,protected=len(protection),drift=[],
                         exact_existing_deltas=5,candidate={n:fingerprint(ROOT/n) for n in ALLOWED},
                         native_tests_run=0,swift_compilation='not run',FPS='not measured',
                         limitations='Lexical/source/protection/synthetic checks only; not UI, FPS, UIKit or Swift runtime execution'), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
