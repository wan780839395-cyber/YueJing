"""Offline source/negative-control/hash checks. No Swift, UI runtime or native tools.
--baseline is this batch's actual pre-edit freeze (never HEAD or an older batch).
Synthetic truth tables describe the intended gate, not execution of a Swift model.
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
PREFIX = 'App/Library/'
FILES = [CONTENT] + [PREFIX + name + '.swift' for name in (
    'LibraryLayout', 'LibraryNavigationShell', 'LibraryShelfContent', 'LibraryExploreSettings',
    'LibraryPlannedEntriesView', 'LibraryPlannedFeatureView')]


def block(text, marker):
    """Exact member comparison; these selected members contain no literal/comment braces."""
    start = text.index(marker)
    tail = text[start:]
    # Include the entire member; no broad state stripping or business-tail normalization.
    depth = 0
    for i, char in enumerate(tail):
        if char == '{': depth += 1
        if char == '}':
            depth -= 1
            if depth == 0: return tail[:i + 1]
    raise AssertionError('Unclosed member: ' + marker)


def contracts(src):
    c, layout, shell, shelf, management, entries, detail = (src[p] for p in FILES)
    checks = []
    def need(ok, label):
        if not ok: raise AssertionError(label)
        checks.append(label)
    for path, text in src.items():
        lexical.check_balanced_delimiters(path, lexical.strip_swift_comments_and_strings(text))
    need(True, 'seven-swift-source-delimiters')
    need('enum LibraryLayout: String, CaseIterable, Sendable' in layout and
         re.findall(r'case (\w+) = "(\w+)"', layout) == [('direct','a'),('tabs','b'),('sidebar','c')], 'stable-three-layout-values')
    need('static let storageKey = "dev.yuejing.ui.libraryLayout.v1"' in layout and
         'static let defaultLayout: LibraryLayout = .tabs' in layout and
         'LibraryLayout(rawValue: rawValue) ?? defaultLayout' in layout, 'independent-key-default-b-read-only-fallback')
    need('@AppStorage(LibraryLayout.storageKey) private var libraryLayoutRawValue = LibraryLayout.defaultLayout.rawValue' in c and
         'LibraryLayout.restored(from: libraryLayoutRawValue)' in c and c.count('@AppStorage(') == 2 and
         '@AppStorage(AppAppearance.storageKey)' in c, 'two-independent-ui-persistence-keys')
    need(c.count('@StateObject private var model: LibraryViewModel') == 1 and c.count('LibraryViewModel(') == 1 and
         c.count('NavigationStack {') == 1 and c.count('.task { await model.start() }') == 1,
         'unique-existing-business-owner-factory-task-stack')
    child = layout + shell + shelf + management + entries + detail
    need(not re.search(r'LibraryViewModel|LibraryService|ReaderTheme|@StateObject|@AppStorage|Task\s*\{|\.task\s*\{|URLSession|UserDefaults|NotificationCenter|Timer', child), 'children-no-business-persistence-or-work')
    need('model.service != nil && model.canPresentLibraryFeedback && !model.importing\n'
         '            && model.encodingChoice?.id == nil && model.message == nil\n'
         '            && readerRoutes.presentation?.id == nil' in c, 'original-six-busy-gates')
    need('canOpenPlannedFeatures && !plannedNavigation.isActive && informationRoute == nil' in c and
         'canNavigateManagement && !drawerPresented' in c and 'model.fileSelection == nil' not in c,
         'root-only-plus-drawer-guard-retained-dismissed-picker-not-trapped')
    for name in ('chooseLayout', 'chooseAppearance', 'openInformation', 'openPlannedFeature'):
        member = block(c, '    private func ' + name)
        need('guard canChangeManagement else { return }' in member, 'action-guard-' + name)
    choose = block(c, '    private func chooseLayout')
    need('libraryLayoutRawValue = option.rawValue' in choose and 'selectedSection = .shelf' in choose and
         'drawerPresented = false' in choose and len(re.findall(r'libraryLayoutRawValue\s*=', c)) == 2,
         'only-user-layout-write-and-reset-to-shelf')
    need('guard canChangeManagement else { return }' in block(c, '    private var sectionSelection:') and
         'guard layout == .sidebar, canChangeManagement else { return }' in block(c, '    private var drawerPresentation:') and
         c.count('guard drawerPresented, canNavigateManagement else { return }') == 2, 'tab-drawer-bindings-and-drawer-actions-guarded')
    need(shell.count('TabView(selection: $section)') == 1 and shell.count('.tabItem {') == 3 and
         'case .direct:\n            shelf\n        case .tabs:' in shell and
         'case .sidebar:\n            switch section' in shell, 'different-a-direct-b-native-tabs-c-sidebar-structures')
    need('rootContent\n                .allowsHitTesting(!drawerPresented)\n                .accessibilityHidden(drawerPresented)' in shell and
         '.allowsHitTesting(drawerPresented)' in shell and 'ScrollView {' in shell and
         'min(300, max(0, proxy.size.width - 32))' in shell and '.keyboardShortcut(.cancelAction)' in shell and
         '.accessibilityAction(.escape)' in shell and 'open ? .close : .menu' in shell,
         'bounded-scrollable-drawer-background-isolation-close-escape-focus')
    need('reduceMotion ? nil : .easeOut(duration: 0.15)' in shell and
         'if reduceMotion { $0.animation = nil }' in shell and '.animation(' not in c + shelf and
         not any(token in child for token in ('withAnimation', '.spring(', '.blur(', 'DragGesture')), 'drawer-only-light-reduced-motion-no-business-animation')
    need('List {' in shelf and 'ForEach(books) { book in' in shelf and
         'LibraryShelfContent(books: model.books' in c and 'Button { onOpenBook(book) }' in shelf and
         not any(x in shelf for x in ('sorted(', 'enumerated(', 'LazyVGrid', '.map(')), 'real-ordered-id-books-list-not-generated')
    need('if layout == .direct {\n                Section {' in shelf and
         'features: LibraryPlannedFeature.modules' in shelf and
         'features: LibraryPlannedFeature.modules' in management and
         'features: [.epub, .cover]' in management, 'a-tail-modules-bc-explore-formats-only-in-management')
    need('features.filter { LibraryPlannedFeature.modules.contains($0) }' in entries and
         'features.filter { !LibraryPlannedFeature.modules.contains($0) }' in entries and
         'NavigationLink' not in entries + shelf + management and entries.count('onOpenFeature(feature)') == 2,
         'explicit-feature-subsets-plain-callbacks-not-row-navigation')
    need(c.count('.navigationDestination(isPresented: plannedFeaturePresentation)') == 1 and
         c.count('.navigationDestination(isPresented: informationPresentation)') == 1 and
         'onOpenFeature: openPlannedFeature' in c and 'plannedNavigation.begin(feature, allowed: canOpenPlannedFeatures)' in c and
         c.index('LibraryNavigationShell(') < c.index('.navigationDestination(isPresented: plannedFeaturePresentation)') < c.index('.accessibilityIdentifier("library.screen")'),
         'single-parent-planned-destination-outside-list-shell')
    need('guard !isPresented, let expectedID else { return }' in c and
         'plannedNavigation.end(id: expectedID)' in c and
         'guard !presented, let expectedID, informationRoute?.id == expectedID else { return }' in c and
         'onDisappear' not in c, 'late-dismissal-ids-and-no-guessed-pop')
    need('LibraryPlannedFeatureView(feature: plannedNavigation.displayedFeature, appearance: appearance)' in c and
         'let appearance: LibraryAppearance' in detail and 'LibraryAppearance(colorScheme:' not in detail and
         '.toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)' in detail, 'details-follow-explicit-current-app-appearance')
    import_control = c[c.index('Button { model.beginFileSelection() } label:'):c.index('.accessibilityHint("当前仅支持 TXT')]
    need(c.count('Button { model.beginFileSelection() }') == 1 and
         'Label("导入", systemImage: "plus")' in import_control and
         '.accessibilityLabel("导入书籍")' in import_control and
         '.disabled(!model.canBeginFileSelection || !canChangeManagement)' in import_control and
         '当前仅支持 TXT；EPUB 规划中，未接入' in c and
         'if let service = model.service { readerRoutes.open(bookID: book.id, service: service) }' in c,
         'one-unified-import-original-action-complete-ax-name-and-bookid-open')
    need('.frame(minWidth: 44, minHeight: LibraryAppearance.minimumControlHeight)' in import_control and
         '.contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))' in import_control and
         'AppControlButtonStyle(foreground: appearance.accent, surface: appearance.accent.opacity(0.12))' in import_control and
         '.stroke' not in import_control and '.padding(' not in import_control[import_control.index('.contentShape('):],
         'soft-import-single-filled-pill-44-hit-shape-no-frame-or-outer-target')
    options = block(management, '    private func optionLabel(')
    need(management.count('.buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 0))') == 2 and
         management.count('.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))') == 2 and
         management.count('.listRowBackground(appearance.groupSurface)') == 1 and
         '.frame(minWidth: 44, maxWidth: .infinity, minHeight: 64, alignment: .leading)' in options and
         '.contentShape(Rectangle())' in options and '.background(' not in options and '.stroke' not in options and
         '.padding(' not in options[options.index('.contentShape('):] and
         'Text(value)' in options and 'chevron.down' in options and 'ViewThatFits(in: .horizontal)' in options,
         'management-menu-shared-group-row-local-press-not-transparent-outer-row')
    need('shape.fill(item == section ? appearance.softSelection : .clear)' in shell and '.strokeBorder(' not in shell and
         'AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 12)' in shell,
         'drawer-only-current-soft-band-no-card-stack')
    need('ReaderDiagnosticsView(importState: model.importDiagnostics, importSummary: model.processingSummary)' in c and
         'Bundle.main.url(forResource: "GRDB-LICENSE", withExtension: "txt")' in management and
         'Text(Self.text)' in management and 'try? String(contentsOf: url, encoding: .utf8)' in management,
         'real-existing-diagnostics-and-entire-local-bundled-license')
    need(all(x not in c + child for x in ('preferredColorScheme', '.environment(\\.colorScheme', '.id(layout)',
         '@Observable', 'import Observation', 'import SwiftData', 'navigationDestination(item:', 'URLSession', 'asyncAfter')),
         'no-reader-scheme-leak-owner-id-reset-new-platform-or-network')
    need('ForEach(AppAppearance.allCases' in management and 'ForEach(LibraryLayout.allCases' in management and
         management.count('systemImage: "checkmark"') == 2 and '.disabled(!canChange)' in management and
         'onAppearance: chooseAppearance' in c and 'onLayout: chooseLayout' in c and
         'AppAppearance.restored(from: appAppearanceRawValue)' in c, 'visible-complete-selection-controls-and-existing-theme-restore')
    return checks


def digest(path):
    value = path.read_bytes()
    return dict(bytes=len(value), sha256=hashlib.sha256(value).hexdigest())


def protection(baseline_path, sources):
    baseline = json.loads(baseline_path.read_text(encoding='utf8'))
    allowed = set(baseline['existing'])
    changed = {p for p, h in baseline['files'].items() if digest(ROOT/p) != h}
    assert changed <= allowed, 'Protected files changed: ' + str(changed - allowed)
    old = (baseline_path.parent/'snapshots'/CONTENT).read_text(encoding='utf8')
    current = sources[CONTENT]
    exact = []
    for marker in ('    init()', '    private static func makeLibraryService', '    private var canOpenPlannedFeatures:',
                   '    private var readerPresentation:', '    private var plannedFeaturePresentation:'):
        assert block(old, marker) == block(current, marker), marker
        exact.append(marker.strip())
    begin, end = '        .accessibilityIdentifier("library.screen")', '    private var '
    assert old[old.index(begin):old.index(end, old.index(begin))] == current[current.index(begin):current.index(end, current.index(begin))]
    exact.append('full stable root attachments: probe/cover/start/memory/reload/picker/encoding/alert')
    env = {**os.environ, 'GIT_OPTIONAL_LOCKS':'0'}
    head = subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, env=env).decode().strip()
    assert head == baseline['head'] and digest(ROOT/'.git/index') == baseline['index']
    assert not subprocess.check_output(['git','diff','--cached','--binary'], cwd=ROOT, env=env)
    return dict(frozen=len(baseline['files']), protected_unchanged=len(baseline['files'])-len(changed),
                changed=sorted(changed), exact_members_and_attachments=exact, head_index_unchanged=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--historical-baseline', '--baseline', dest='baseline', type=Path, help='Historical navigation batch hash protection only; current paint is validated by default')
    args = parser.parse_args()
    sources = {p:(ROOT/p).read_text(encoding='utf8') for p in FILES}
    checked = contracts(sources)
    if not args.baseline:
        from check_ui_control_cohesion import current_exact
        exact_paint = current_exact(sources)
    else:
        exact_paint = 'historical hash mode; no current freeze substitution'
    controls = [
        ('wrong-layout-key', FILES[1], 'dev.yuejing.ui.libraryLayout.v1', 'dev.yuejing.ui.appAppearance.v1'),
        ('wrong-default', FILES[1], 'defaultLayout: LibraryLayout = .tabs', 'defaultLayout: LibraryLayout = .direct'),
        ('missing-busy-gate', CONTENT, ' && model.message == nil', ''),
        ('missing-push-gate', CONTENT, ' && !plannedNavigation.isActive', ''),
        ('unguarded-layout-write', CONTENT, 'guard canChangeManagement else { return }\n        libraryLayoutRawValue', 'libraryLayoutRawValue'),
        ('unguarded-tab-setter', CONTENT, 'guard canChangeManagement else { return }\n            selectedSection', 'selectedSection'),
        ('reset-owner', CONTENT, '.accessibilityIdentifier("library.screen")', '.id(layout).accessibilityIdentifier("library.screen")'),
        ('reader-scheme-leak', CONTENT, 'NavigationStack {', 'NavigationStack { Color.clear.preferredColorScheme(.dark)'),
        ('detail-default-leak', CONTENT, 'displayedFeature, appearance: appearance)', 'displayedFeature)'),
        ('duplicate-planned-destination', CONTENT, '.navigationDestination(isPresented: plannedFeaturePresentation)', '.navigationDestination(isPresented: plannedFeaturePresentation) {}\n.navigationDestination(isPresented: plannedFeaturePresentation)'),
        ('background-ax-leak', FILES[2], '.accessibilityHidden(drawerPresented)', '.accessibilityHidden(false)'),
        ('child-service-owner', FILES[2], 'let layout: LibraryLayout', 'let model: LibraryViewModel\n    let layout: LibraryLayout'),
        ('lost-format-group', FILES[4], 'features: [.epub, .cover]', 'features: [.comics, .aiStory]'),
        ('wrong-import-action', CONTENT, 'Button { model.beginFileSelection() }', 'Button { model.cancelImport() }'),
        ('wrong-import-ax-name', CONTENT, '.accessibilityLabel("导入书籍")', '.accessibilityLabel("打开")'),
        ('import-under44', CONTENT, 'minHeight: LibraryAppearance.minimumControlHeight', 'minHeight: 32'),
        ('import-extra-transparent-target', CONTENT, '.contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))', '.contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous)).padding(8)'),
        ('menu-auto-list-row', FILES[4], '.buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 0))', '.buttonStyle(.automatic)'),
        ('menu-expanded-row', FILES[4], '.contentShape(Rectangle())', '.contentShape(Rectangle()).padding(8)'),
        ('menu-under44', FILES[4], 'minWidth: 44, maxWidth: .infinity, minHeight: 64', 'minWidth: 32, maxWidth: .infinity, minHeight: 32'),
        ('drawer-all-selected', FILES[2], 'item == section ? appearance.softSelection : .clear', 'true ? appearance.softSelection : .clear'),
    ]
    rejected = []
    for label, path, old, new in controls:
        assert old in sources[path], label
        changed = dict(sources); changed[path] = changed[path].replace(old, new, 1)
        try: contracts(changed)
        except (AssertionError, ValueError): rejected.append(label)
        else: raise AssertionError('Accepted negative control: '+label)
    # Specification truth table only: each busy/root condition independently denies a write.
    gates = ['service','feedback','not-importing','no-encoding','no-message','no-reader','no-planned-push','no-info-push','no-drawer']
    specification = {name: not all([True]*i+[False]+[True]*(len(gates)-i-1)) for i,name in enumerate(gates)}
    assert all(specification.values()) and all([True]*len(gates))
    checked.append('current-exact-paint-deltas-business-rest-equal' if not args.baseline else 'explicit-historical-mode')
    result = dict(kind='OFFLINE_SOURCE_HASH_AND_SPEC_NOT_NATIVE', source_checks=len(checked), checks=checked,
                  negative_controls_rejected=rejected, synthetic_gate_truth_table=specification,
                  protection=protection(args.baseline,sources) if args.baseline else 'not requested',
                  native_compilations=0, native_executions=0, ui_touch_tests=0, persistence_runtime_tests=0)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__': main()
