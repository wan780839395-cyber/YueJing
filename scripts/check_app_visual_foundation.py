"""Offline Swift SOURCE contracts / in-memory negative controls, never native execution.
Optional --snapshot-root compares against this batch's actual pre-edit Swift copies.
No user defaults, library service, Swift model or native tool is executed.
"""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
STYLE = 'App/AppVisualStyle.swift'
CONTENT = 'App/ContentView.swift'
LIBRARY = 'App/Library/LibraryAppearance.swift'
READER = 'App/Reading/ReaderVisualStyle.swift'
KEY = 'dev.yuejing.ui.appAppearance.v1'


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
    menu = content[content.index('    private var appAppearanceMenu:'):content.index('    private var readerPresentation:')]
    require('appAppearanceMenu\n                }' in content and 'Menu {' in menu and
            'ForEach(AppAppearance.allCases, id: \\.self)' in menu, 'toolbar-menu-and-all-cases')
    require('guard canOpenPlannedFeatures else { return }' in menu and
            '.disabled(!canOpenPlannedFeatures)' in menu, 'disabled-and-late-action-gate')
    require('appAppearanceRawValue = option.rawValue' in menu and
            len(re.findall(r'appAppearanceRawValue\s*=', content)) == 2, 'only-explicit-selection-writes')
    require('Label("\\(option.title) · 当前", systemImage: "checkmark")' in menu and
            'Text(option.title)' in menu and '.accessibilityValue(appAppearance.title)' in menu and
            '.accessibilityLabel("App 外观，\\(option.title)")' in menu and
            '.frame(minWidth: 44, minHeight: AppVisualStyle.minimumControlHeight)' in menu and
            '.font(AppVisualStyle.actionFont)' in menu, 'text-checkmark-ax-and-semantic-44pt-control')
    require(not re.search(r'\b(model|readerRoutes|Task|Timer|NotificationCenter|UserDefaults)\b', menu), 'menu-no-service-task-or-reader-effects')
    require(all(word not in style + library for word in ('ReaderTheme', 'ReaderDomain', 'LibraryService', '@AppStorage', 'UserDefaults', 'Task {', 'Timer')),
            'foundation-ui-only-no-reading-mapping-or-service')
    require(all(word not in style + content + library + reader for word in
                ('preferredColorScheme', '.environment(\\.colorScheme', '@Observable', 'import SwiftData', 'EnvironmentKey')),
            'no-global-scheme-or-new-state-architecture')
    require('@MainActor\nstruct AppVisualStyle' in style and '@MainActor\nenum AppAppearance' not in style,
            'ui-token-access-main-actor-not-pure-enum')
    for role in ('page', 'surface', 'foreground', 'secondary', 'edge', 'accent', 'coverSurface'):
        require(f'var {role}: Color {{ style.{role} }}' in library, 'library-role-' + role)
    require(all(x in content for x in ('LibraryHeaderView(bookCount: model.books.count, appearance: appearance)',
                'LibraryBookRow(book: book, appearance: appearance)', 'LibraryPlannedEntriesView(appearance: appearance,',
                '.background(appearance.page.ignoresSafeArea())', '.foregroundStyle(appearance.foreground)', '.tint(appearance.accent)')),
            'existing-shelf-consumers-use-tokens')
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
    parser.add_argument('--snapshot-root', type=Path, help='Actual pre-edit copies, not HEAD')
    args = parser.parse_args()
    sources = {p: (ROOT / p).read_text(encoding='utf-8') for p in (STYLE, CONTENT, LIBRARY, READER)}
    checks = contracts(sources)
    mutations = [
        ('wrong-key', STYLE, KEY, 'dev.yuejing.reader.theme'),
        ('reader-theme-mapping', STYLE, 'AppAppearance(rawValue: rawValue)', 'ReaderTheme(rawValue: rawValue)'),
        ('preferred-scheme-leak', CONTENT, '.listStyle(.plain)', '.listStyle(.plain).preferredColorScheme(.dark)'),
        ('lost-busy-gate', CONTENT, ' && model.message == nil', ''),
        ('lost-selection-wire', CONTENT, 'appAppearance: appAppearance)', 'appAppearance: .mist)'),
        ('fallback-write', CONTENT, 'appAppearanceRawValue = option.rawValue', 'appAppearanceRawValue = option.rawValue; appAppearanceRawValue = "mist"'),
        ('service-side-effect', CONTENT, 'appAppearanceRawValue = option.rawValue', 'appAppearanceRawValue = option.rawValue; model.savePreferences()'),
        ('reader-color-drift', READER, 'rgb(36, 45, 39)', 'rgb(1, 2, 3)'),
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
    print(json.dumps(dict(kind='OFFLINE_SOURCE_CONTRACTS_NOT_NATIVE', source_checks=len(checks),
                          checks=checks, negative_controls_rejected=rejected, snapshot_comparison=comparison,
                          native_compilations=0, native_executions=0, persistence_runtime_tests=0), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
