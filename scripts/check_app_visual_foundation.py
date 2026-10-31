"""Offline Swift SOURCE contracts / in-memory negative controls, never native execution.
Optional --snapshot-root compares against this batch's actual pre-edit Swift copies.
No user defaults, library service, Swift model or native tool is executed.
"""
import argparse
import json
from pathlib import Path
import re

import check_library_navigation_schemes as navigation

ROOT = Path(__file__).resolve().parents[1]
STYLE = 'App/AppVisualStyle.swift'
CONTENT = 'App/ContentView.swift'
LIBRARY = 'App/Library/LibraryAppearance.swift'
READER = 'App/Reading/ReaderVisualStyle.swift'
KEY = 'dev.yuejing.ui.appAppearance.v1'
MANAGEMENT = 'App/Library/LibraryExploreSettings.swift'
SHELF = 'App/Library/LibraryShelfContent.swift'
SHELL = 'App/Library/LibraryNavigationShell.swift'
LAYOUT = 'App/Library/LibraryLayout.swift'
FILES = (STYLE, CONTENT, LIBRARY, READER, MANAGEMENT, SHELF, SHELL, LAYOUT)


def contracts(sources):
    style, content, library, reader = (sources[p] for p in (STYLE, CONTENT, LIBRARY, READER))
    checked = []

    def require(ok, name):
        if not ok:
            raise AssertionError(name)
        checked.append(name)

    require('enum AppAppearance: String, CaseIterable, Sendable' in style, 'sendable-value-enum')
    require(re.findall(r'case (\w+) = "(\w+)"', style) ==
            [('clear', 'clear'), ('mist', 'mist'), ('ink', 'ink')], 'stable-raw-values')
    require(all(f'case .{value}: "{title}"' in style for value, title in
                [('clear', '清朗'), ('mist', '柔雾'), ('ink', '墨夜')]), 'three-complete-titles')
    require(f'static let storageKey = "{KEY}"' in style, 'dedicated-storage-key')
    require('static let defaultAppearance: AppAppearance = .mist' in style and
            'AppAppearance(rawValue: rawValue) ?? defaultAppearance' in style, 'unknown-value-read-only-mist-fallback')
    require('@AppStorage(AppAppearance.storageKey) private var appAppearanceRawValue = AppAppearance.defaultAppearance.rawValue' in content
            and 'AppAppearance.restored(from: appAppearanceRawValue)' in content, 'storage-and-restore-wired')
    require('LibraryAppearance(colorScheme: colorScheme, appAppearance: appAppearance)' in content and
            'init(colorScheme: ColorScheme, appAppearance: AppAppearance = .defaultAppearance)' in library and
            'AppVisualStyle(appearance: appAppearance, colorScheme: colorScheme)' in library, 'explicit-appearance-and-compatible-init')
    require('model.service != nil && model.canPresentLibraryFeedback && !model.importing\n'
            '            && model.encodingChoice?.id == nil && model.message == nil\n'
            '            && readerRoutes.presentation?.id == nil' in content, 'six-original-busy-gates')
    management, shelf, shell, layout = (sources[p] for p in (MANAGEMENT, SHELF, SHELL, LAYOUT))
    menu = management[management.index('Section("外观与入口")'):management.index('Section("格式与书籍显示")')]
    selection = navigation.block(content, '    private func chooseAppearance(')
    require('Menu { managementOptions(asMenu: true) } label:' in content and
            r'ForEach(AppAppearance.allCases, id: \.self)' in menu and
            'LibrarySettingsContent(appearance: appearance, options: managementOptions(asMenu: false))' in content and
            'onAppearance: chooseAppearance' in content and 'Button { onAppearance(option) } label:' in menu,
            'shared-menu-and-bc-settings-all-cases-original-selection-wire')
    require('guard canChangeManagement else { return }' in selection and '.disabled(!canChange)' in menu and
            'canNavigateManagement && !drawerPresented' in content,
            'root-busy-drawer-disabled-and-late-action-gates')
    require(selection == '    private func chooseAppearance(_ option: AppAppearance) {\n'
                         '        guard canChangeManagement else { return }\n'
                         '        appAppearanceRawValue = option.rawValue\n    }' and
            len(re.findall(r'appAppearanceRawValue\s*=', content)) == 2,
            'only-guarded-explicit-selection-writes-no-side-effects')
    require('Label("\\(option.title) · 当前", systemImage: "checkmark")' in menu and
            'Text(option.title)' in menu and '.accessibilityValue(appAppearance.title)' in menu and
            '.accessibilityLabel("App 外观，\\(option.title)")' in menu and
            'optionLabel("外观", value: appAppearance.title' in menu,
            'current-selection-text-checkmark-value-and-ax-label')
    option = navigation.block(management, '    private func optionLabel(')
    require('.frame(minWidth: 44, maxWidth: .infinity, minHeight: 44, alignment: .leading)' in option and
            'let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)' in option and
            'shape.fill(appearance.surface)' in option and 'shape.strokeBorder(appearance.edge, lineWidth: 0.8)' in option and
            '.contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))' in option and
            '.allowsHitTesting(false)' in option and '.inset(' not in option and '.clipShape(' not in option and
            option.index('.padding(12)') < option.index('.frame(minWidth: 44') < option.index('.background {') < option.index('.contentShape(') and
            '.padding(' not in option[option.index('.contentShape('):] and
            '.buttonStyle(.plain)' in menu and '.listRowBackground(Color.clear)' in menu,
            'visible-menu-card-44-surface-stroke-shape-not-implicit-row')
    require(not re.search(r'\b(model|readerRoutes|Task|Timer|NotificationCenter|UserDefaults)\b', menu+option), 'menu-no-service-task-or-reader-effects')
    require('dev.yuejing.ui.libraryLayout.v1' in layout and KEY not in layout and
            '@AppStorage(LibraryLayout.storageKey) private var libraryLayoutRawValue' in content and
            'LibraryLayout.restored(from: libraryLayoutRawValue)' in content and
            content.count('@StateObject private var model: LibraryViewModel') == 1 and
            content.count('.task { await model.start() }') == 1,
            'independent-layout-persistence-and-single-existing-owner-task')
    require(all(word not in style + library for word in ('ReaderTheme', 'ReaderDomain', 'LibraryService', '@AppStorage', 'UserDefaults', 'Task {', 'Timer')),
            'foundation-ui-only-no-reading-mapping-or-service')
    require(all(word not in style + content + library + reader for word in
                ('preferredColorScheme', '.environment(\\.colorScheme', '@Observable', 'import SwiftData', 'EnvironmentKey')),
            'no-global-scheme-or-new-state-architecture')
    require('@MainActor\nstruct AppVisualStyle' in style and '@MainActor\nenum AppAppearance' not in style,
            'ui-token-access-main-actor-not-pure-enum')
    for role in ('page', 'surface', 'foreground', 'secondary', 'edge', 'accent', 'coverSurface'):
        require(f'var {role}: Color {{ style.{role} }}' in library, 'library-role-' + role)
    require(all(x in shelf for x in ('LibraryHeaderView(bookCount: books.count, appearance: appearance)',
                'LibraryBookRow(book: book, appearance: appearance)', 'LibraryPlannedEntriesView(appearance: appearance,',
                '.background(appearance.page.ignoresSafeArea())', '.foregroundStyle(appearance.foreground)', '.tint(appearance.accent)')) and
            'LibraryShelfContent(books: model.books' in content and
            '.toolbarColorScheme(appearance.controlColorScheme, for: .tabBar)' in shell,
            'existing-extracted-shelf-and-shell-consumers-use-explicit-tokens')
    require(all(x in style for x in ('case (.clear, .light):', 'case (.clear, _):',
                'case (.mist, .light):', 'case (.mist, _):', 'case (.ink, _):')),
            'three-palettes-system-light-dark-handled')
    require('AppAppearance' not in reader and '@AppStorage' not in reader and 'colorScheme' not in reader,
            'reader-does-not-consume-app-selection')
    for name, dark, light in [('surface', '36, 45, 39', '250, 251, 247'),
                              ('edge', '58, 71, 61', '223, 229, 219'),
                              ('accent', '212, 172, 144', '139, 91, 76'),
                              ('sectionSurface', '42, 52, 45', '252, 253, 249')]:
        require(f'static func {name}(for theme: ReaderTheme) -> Color {{\n'
                f'        theme == .dark ? rgb({dark}) : rgb({light})\n    }}' in reader,
                'reader-original-theme-colors-' + name)
    for token, value in [('minimumControlHeight', '44'), ('compactSpacing', '8'), ('dividerHeight', '0.5')]:
        require(f'static let {token}: CGFloat = {value}' in style and f'AppVisualStyle.{token}' in reader,
                'shared-constant-unchanged-' + token)
    require('.system(.title, design: .serif).weight(.medium)' in style and
            '.subheadline.weight(.medium)' in style and 'AppVisualStyle.panelTitleFont' in reader and
            'AppVisualStyle.actionFont' in reader, 'reader-semantic-fonts-unchanged')
    return checked


def snapshot_comparisons(sources, root):
    """Reverse only this batch's exact UI edits; compare the complete original text."""
    content = sources[CONTENT]
    menu_start = content.index('    private var appAppearanceMenu:')
    content = content[:menu_start] + content[content.index('    private var readerPresentation:'):]
    content = content.replace('    @AppStorage(AppAppearance.storageKey) private var appAppearanceRawValue = AppAppearance.defaultAppearance.rawValue\n', '')
    content = content.replace('    private var appAppearance: AppAppearance { AppAppearance.restored(from: appAppearanceRawValue) }\n'
                              '    private var appearance: LibraryAppearance {\n'
                              '        LibraryAppearance(colorScheme: colorScheme, appAppearance: appAppearance)\n    }',
                              '    private var appearance: LibraryAppearance { LibraryAppearance(colorScheme: colorScheme) }')
    content = content.replace('            .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)\n', '')
    content = content.replace('                ToolbarItem(placement: .navigationBarTrailing) {\n'
                              '                    appAppearanceMenu\n                }\n', '')
    content = content.replace('.foregroundStyle(appearance.secondary).fixedSize', '.foregroundStyle(.secondary).fixedSize')
    reader = sources[READER]
    for new, old in [('AppVisualStyle.compactSpacing', '8'), ('AppVisualStyle.dividerHeight', '0.5'),
                     ('AppVisualStyle.minimumControlHeight', '44'),
                     ('AppVisualStyle.panelTitleFont', '.system(.title, design: .serif).weight(.medium)'),
                     ('AppVisualStyle.actionFont', '.subheadline.weight(.medium)')]:
        reader = reader.replace(new, old)
    results = {}
    for path, normalized in [(CONTENT, content), (READER, reader)]:
        expected = (root / path).read_text(encoding='utf-8')
        if normalized != expected:
            raise AssertionError('Reverse-normalized original differs: ' + path)
        results[path] = 'complete-text-equal-after-listed-ui-substitutions'
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshot-root', type=Path, help='Historical foundation-v1 pre-edit copies only; not current source protection')
    args = parser.parse_args()
    sources = {p: (ROOT / p).read_text(encoding='utf-8') for p in FILES}
    checks = contracts(sources)
    mutations = [
        ('wrong-key', STYLE, KEY, 'dev.yuejing.reader.theme'),
        ('reader-theme-mapping', STYLE, 'AppAppearance(rawValue: rawValue)', 'ReaderTheme(rawValue: rawValue)'),
        ('preferred-scheme-leak', CONTENT, 'NavigationStack {', 'NavigationStack { Color.clear.preferredColorScheme(.dark)'),
        ('lost-busy-gate', CONTENT, ' && model.message == nil', ''),
        ('lost-selection-wire', CONTENT, 'onAppearance: chooseAppearance', 'onAppearance: { _ in }'),
        ('fallback-write', CONTENT, 'appAppearanceRawValue = option.rawValue', 'appAppearanceRawValue = option.rawValue; appAppearanceRawValue = "mist"'),
        ('service-side-effect', CONTENT, 'appAppearanceRawValue = option.rawValue', 'appAppearanceRawValue = option.rawValue; model.savePreferences()'),
        ('reader-color-drift', READER, 'rgb(36, 45, 39)', 'rgb(1, 2, 3)'),
        ('layout-persist-confusion', LAYOUT, 'dev.yuejing.ui.libraryLayout.v1', KEY),
        ('menu-under44', MANAGEMENT, 'minWidth: 44, maxWidth: .infinity, minHeight: 44', 'minWidth: 32, maxWidth: .infinity, minHeight: 32'),
        ('menu-shape-mismatch', MANAGEMENT, 'contentShape(RoundedRectangle(cornerRadius: 12', 'contentShape(RoundedRectangle(cornerRadius: 8'),
        ('menu-visible-inset', MANAGEMENT, 'shape.fill(appearance.surface)', 'shape.inset(by: 6).fill(appearance.surface)'),
    ]
    rejected = []
    for name, path, before, after in mutations:
        assert before in sources[path], 'Negative control not applicable: ' + name
        changed = dict(sources)
        changed[path] = changed[path].replace(before, after, 1)
        try:
            contracts(changed)
        except AssertionError:
            rejected.append(name)
        else:
            raise AssertionError('Accepted negative control: ' + name)
    comparison = snapshot_comparisons(sources, args.snapshot_root) if args.snapshot_root else 'not-requested'
    # The optional reverse-normalization is historical foundation-v1 evidence,
    # never a substitute for current live-source contracts or the new batch freeze.
    print(json.dumps(dict(kind='OFFLINE_SOURCE_CONTRACTS_NOT_NATIVE', source_checks=len(checks),
                          checks=checks, negative_controls_rejected=rejected, snapshot_comparison=comparison,
                          native_compilations=0, native_executions=0, persistence_runtime_tests=0), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
