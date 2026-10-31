"""Task-specific offline source/negative controls. No Swift, UIKit or touch execution.

Approved presentation fragments are pinned, not stripped by modifier name. All
remaining source must equal the verified fdbdca0 pre-edit bytes, including actions,
AX IDs, owner/lifecycle, persistence and focus. Does not modify any file.
"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess

import check_navigation_panel_layout as lexical
import check_reader_dock_schemes as dock
import task3_test_inventory as inventory

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'artifacts/ui-inspection-20261031/baseline.json'
HEAD = 'fdbdca0938b60cd2a3cc60389e8bffa9e04f3a89'
CONTENT = 'App/ContentView.swift'
MANAGEMENT = 'App/Library/LibraryExploreSettings.swift'
SHELL = 'App/Library/LibraryNavigationShell.swift'
TOOLS = 'App/Reading/ReaderFloatingToolsView.swift'
STYLE = 'App/Reading/ReaderCompactButtonStyle.swift'
SETTINGS = 'App/Reading/ReaderSettingsView.swift'
ADJUSTMENT = 'App/Reading/ReaderSettingAdjustment.swift'
FOOTER = 'App/Reading/ReaderDirectoryFooter.swift'
NEW = ['scripts/check_ui_control_cohesion.py', 'docs/UI_CONTROL_COHESION_LOCAL.md']
# [old start,end, live start,end, live fragment SHA256], zero-based half-open lines.
# Each unequal opcode is exact; neither entire functions/files nor all frames or
# backgrounds are masked. Full diff is retained separately for human review.
PATCHES = {
 CONTENT: [
  [66,66,66,69,'abdf5ee67611680378ad830188ba6ea73d2f0624d737ff88400f65fa8baa2312'],
  [67,68,70,77,'fa09bede660e5d80fd7d40bbc24f2706546ef2c8e143821f30e8f2a6b116a48f'],
  [69,69,78,79,'8fbc1bc339b9295c071846321cbcfaee163c118600e28367341d2e12c336fd13'],
  [75,76,85,91,'4a2ae441776c4623786bbb3f8588eb7e92fd4c80a6c19b4f809e965da1f7084b'],
  [77,79,92,99,'d65efd94ca84b6f103f7cedd1e904c132435f42a12f3d436882752162a3dfe73'],
  [80,80,100,102,'70b2a1245a9f8b3a387e1f3653fd6335025816bd9617b918ba45e19e5e16a1de']],
 MANAGEMENT: [
  [61,64,61,62,'6f23aaa37f6472185022f895544c9e7dbd800a6d657a8f36713f13b0a33334b0'],
  [65,65,63,66,'fbaa5b7b6d305448a8f945ecdd8454a0cc7a68863d934c044cf44be4f68f5619'],
  [78,81,79,80,'0693c3e5b8d338c39ab877e792b800035049775f4da9af02be91fda1d8fc655e'],
  [82,82,81,84,'fbaa5b7b6d305448a8f945ecdd8454a0cc7a68863d934c044cf44be4f68f5619'],
  [83,83,85,86,'3b326345f01b745199fe26cecf4d5aa8de946a940fd2ce7e559829cf5e4d42e0'],
  [84,85,87,88,'95c565a01696419cdac26db040118038d068ed0470b254917ab8c5f58bc9af93'],
  [104,104,107,143,'d78458633ad40f0c39ad3914ae7b5c3dd9764fc2e445b0bc80f76f9aad30afad']],
 SHELL: [
  [34,34,34,37,'34438ee6fce8585a6eba7a24d165ae1b64e5f7201c29a3798c53a670978cb7f0'],
  [35,35,38,45,'eeb38296331d6a8531d6d7dd26c963ab6bb119db7cbf8fca3ed8c3f9e4708da9'],
  [36,36,46,47,'55a4a87c606bf95bf5cb5266f08dfdd0fd84eb89c1cb0633dc7ac969790f5f9c'],
  [80,81,91,101,'c2c6225a6e8a3a75e8e9acad89b9928be7509e73bfcbac16154f675ac8868070'],
  [82,82,102,103,'4910e696b6e3de473460364628657892ef250a99b567508d5dbd0c333cadbd00'],
  [92,92,113,115,'9c697e0449c36c0a2109138d5481dec257c33918195d21aa1f1a05292be26c9b'],
  [94,94,117,124,'8b73f84a0662394b9cc89fde58f7b85304cece99b9f46a013f3d9ab3516a3faa'],
  [95,95,125,126,'e3064062d9c0d1992df079e6cc9de715f1936fa3dd98490bff1351e7ac8fba0c']],
 TOOLS: [
  [112,113,112,114,'a31ca3b436c3d4e8598a4e65279f0fa2cad5124e434ab1d70b380fe21580b3ad'],
  [114,115,115,122,'af575c2d95d7daa793b44a1f3db1d00741e17467a7e2b9accb76a7fc596e3710'],
  [120,124,127,127,'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'],
  [138,139,141,143,'e70b0e7f592f7651320fae92c47ab6e7606c36fbaddcf27f25eed28cee24fb03'],
  [140,141,144,146,'5cac1c5e2306fe4d75146959164cc2ce3ce5216e087279d0e5701d0737fca55b'],
  [142,143,147,148,'b2c2f6a0fe7c200a66ba2f5603c5687f26f4f826a389dd893ee637271f086552'],
  [165,165,170,173,'ed0e0e86ba77a89f76e89ae71b4171eb78450e673261267242ca9542d4398e6b'],
  [166,167,174,174,'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'],
  [168,169,175,176,'a4e0e2f88b32b18c4ae9cee43922bf57a260abe3228a4395ab52059662ae84d1']],
 STYLE: [
  [2,4,2,4,'11a14b1ca600357adb55d66d53715098120d8ff6b0e9f9974d8e170de4c2a2b4'],
  [7,9,7,8,'d7f01e5b15fb337386bdd876402e133400825e2e612b961d492ed51851870ba3'],
  [11,11,10,16,'c4ad19270bd3fd9a8036d251daeb2412695830341d422fde231f21a39f245859'],
  [16,16,21,23,'f7f11d0bda8d8a20f8113faef589022d715c0749d492597189d95bf3223d4cf7'],
  [19,20,26,26,'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'],
  [27,27,33,34,'a0505057a35a23a0e2332a9312e7f4ecb11695cbb4e310ae546a584906341ed4']],
 SETTINGS: [
  [37,38,37,37,'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'],
  [39,40,38,39,'62702735e9999f7e59c4163e81c8cbae85f0c2f6d6074d0a1069089a3eba7484'],
  [151,151,150,151,'a0505057a35a23a0e2332a9312e7f4ecb11695cbb4e310ae546a584906341ed4'],
  [167,167,167,168,'a0505057a35a23a0e2332a9312e7f4ecb11695cbb4e310ae546a584906341ed4'],
  [168,169,169,170,'79c7e2d3f12e7279deacfc65093cf1dcf67c9dd1fbd077343b400e602072b00b'],
  [187,188,188,188,'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'],
  [189,190,189,190,'cf132aee707ddcace408c4c80686f46d917cd0b3fd4b8124dd17edc40b281992'],
  [228,229,228,229,'8736dbc8257bdd136c52fb248f941c6580c26cb7d7e31aa298a0b5381f02f7db'],
  [230,242,230,241,'8e3a193c7baad782e1939489a1472cea8f3b5fec5ea768f5a043d66745edaeec'],
  [243,250,242,246,'ca5a53ef92ab22d6d9ed7563772b65beae79e2df9cd8a62074b68218f91b70bd'],
  [251,253,247,262,'0a561aea61f1136d8c2d33e2d27fee538e8b1e0d41657ea48833c2905d78e92c']],
 ADJUSTMENT: [
  [45,47,45,47,'17fd18829675d6af8757543e261f0c81865cd174b0376725d75085f3204f8934'],
  [58,60,58,60,'c7b81148bd8ecb0f4be00ec57f0ada32a55945187624fba58a8b14fde017e64b']],
 FOOTER: [
  [126,127,126,126,'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'],
  [128,129,127,128,'cf132aee707ddcace408c4c80686f46d917cd0b3fd4b8124dd17edc40b281992'],
  [151,152,150,150,'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'],
  [153,154,151,152,'cf132aee707ddcace408c4c80686f46d917cd0b3fd4b8124dd17edc40b281992']]
}


def digest_bytes(data):
    return dict(sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))


def digest_file(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return dict(sha256=h.hexdigest(), bytes=path.stat().st_size)


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT,
                                   env={**os.environ, 'GIT_OPTIONAL_LOCKS': '0'})


def load_before(baseline):
    before = {}
    for p in PATCHES:
        data = git('show', HEAD + ':' + p)
        assert digest_bytes(data) == baseline['files'][p], 'HEAD not actual pre-edit bytes: ' + p
        before[p] = data.decode('utf8')
    return before


def reverse_presentation(sources, before):
    """Exact narrow reversals only; returns source for legacy behavior comparisons."""
    restored = dict(sources)
    for p, approved in PATCHES.items():
        a, b = before[p].splitlines(keepends=True), sources[p].splitlines(keepends=True)
        actual = [[i,j,k,l,hashlib.sha256(''.join(b[k:l]).encode()).hexdigest()]
                  for op,i,j,k,l in difflib.SequenceMatcher(None,a,b,autojunk=False).get_opcodes() if op != 'equal']
        assert actual == approved, 'Non-approved source delta: ' + p
        for i,j,k,l,_ in reversed(approved):
            b[k:l] = a[i:j]
        restored[p] = ''.join(b)
        assert restored[p] == before[p], 'Business/behavior changed outside exact visual fragments: ' + p
    return restored


def member(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


def source_contracts(s):
    checks = []
    def need(ok, name):
        assert ok, name
        checks.append(name)
    shape12 = 'RoundedRectangle(cornerRadius: 12, style: .continuous)'
    for p in PATCHES:
        code = lexical.strip_swift_comments_and_strings(s[p])
        lexical.check_balanced_delimiters(p, code)
        need(not any(t in code for t in ('@Observable','import Observation','import SwiftData','.snappy',
             'symbolEffect','minimumScaleFactor','lineLimit(1)','zIndex','DragGesture','onTapGesture')),
             p + ':balanced-ios16-no-new-gesture-forced-shrink')
    c, m, shell, tools, style, settings, adj, footer = (s[p] for p in PATCHES)
    for name, fragment in [('a-menu', member(c,'Menu { managementOptions(asMenu: true)', 'if layout == .direct ||')),
                           ('import', member(c,'Button { model.beginFileSelection()', '.disabled(!model.canBeginFileSelection')),
                           ('c-menu', member(shell,'Button { drawerPresented = true', '.disabled(!canNavigate ||'))]:
        need('.frame(minWidth: 44, minHeight:' in fragment and '.background {' in fragment
             and 'let shape = '+shape12 in fragment and 'shape.fill(' in fragment
             and 'shape.strokeBorder(' in fragment and '.contentShape('+shape12+')' in fragment
             and '.allowsHitTesting(false)' in fragment and '.buttonStyle(.plain)' in fragment,
             name + ':visible-surface-44-matching-shape-no-system-double-enclosure')
        tail = fragment[fragment.index('.contentShape('):]
        need('.padding(' not in tail and '.frame(' not in tail, name + ':no-outside-hit-padding')
    need('.labelStyle(.iconOnly)' in c and '.accessibilityLabel("导入书籍")' in c,
         'compact-a-entry-and-import-retains-full-ax-name')
    menu_region = member(m, 'Section("外观与入口")', 'Section("格式与书籍显示")')
    need(menu_region.count('Menu {') == 2 and menu_region.count('optionLabel(') == 2
         and menu_region.count('.buttonStyle(.plain)') == 2
         and menu_region.count('.listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))') == 2
         and menu_region.count('.listRowSeparator(.hidden)') == 2
         and '.listRowBackground(Color.clear)' in menu_region, 'menus:explicit-not-auto-list-row-disambiguation-clear-exterior')
    option = member(m, 'private func optionLabel(', '\n@MainActor\nstruct LibraryLicenseView')
    need('if asMenu {' in option and 'Text(detail)' in option and ' · 当前' in option
         and 'minWidth: 44, maxWidth: .infinity, minHeight: 44' in option,
         'menus:one-step-current-value-detail-full-visible-card-44')
    need(option.index('.padding(12)') < option.index('.frame(minWidth: 44') < option.index('.background {')
         < option.index('.contentShape('+shape12+')')
         and 'let shape = '+shape12 in option and 'shape.fill(appearance.surface)' in option
         and 'shape.strokeBorder(appearance.edge' in option and '.allowsHitTesting(false)' in option,
         'menus:surface-stroke-shape-at-same-label-boundary')
    need('.padding(' not in option[option.index('.contentShape('):], 'menus:external-whitespace-not-control')
    need('.inset(' not in style and '.frame(minWidth: 44, minHeight: 44)' in style
         and '.contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))' in style
         and 'let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)' in style
         and 'shape.strokeBorder(' in style and '.allowsHitTesting(false)' in style,
         'shared-style:visible-44-not-old-32-same-shape-bounds')
    need('surfaceInset _: CGFloat = 0' in style and 'surfaceInset: 0, outlined: true' in s['App/Reading/ReaderDirectorySheet.swift'],
         'unchanged-directory-close-zero-inset-callsite-remains-compatible')
    for name, start, end in [('preset','private func presetButton','private var restoreTypographyButton'),
                             ('theme','private func themeButton','private func apply(')]:
        card = member(settings,start,end)
        label = card[card.index('} label: {'):]
        need(label.index('.frame(minWidth: 84') < label.index('.background {')
             < label.index('.overlay(alignment: .topTrailing)') < label.index('.contentShape('+shape12+')')
             and 'let shape = '+shape12 in card and 'shape.fill(selected ?' in card
             and 'shape.strokeBorder(selected ?' in card and card.count('.allowsHitTesting(false)') == 2,
             name + ':whole-card-selected-surface-stroke-focus-shape-not-swatch-only')
        need('.accessibilityValue(selected ? "已选择" : "未选择")' in card
             and '.accessibilityAddTraits(selected ? .isSelected : [])' in card
             and card.count('.opacity(selected ? 1 : 0)') == 1, name + ':noncolor-selection-ax-retained')
        need(card.count('let selectionAnimation = reduceMotion ? nil : ReaderMotion.selectionFeedback') == 1
             and card.count('if reduceMotion { transaction.animation = nil }') == 2
             and card.count('.animation(selectionAnimation, value: selectionMotionKey)') == 2
             and '.animation(' not in card[card.index('.contentShape('):], name + ':only-local-decoration-motion-with-reduce-motion')
    theme = member(settings,'private func themeButton','private func apply(')
    need(theme.index('Text(theme.title)') < theme.index('.frame(minWidth: 84'), 'theme:title-inside-selected-card')
    need('Button { step(-1) } label:' in adj and 'Button { step(1) } label:' in adj
         and adj.count('.frame(minWidth: 44, minHeight: 44)') == 2
         and adj.count('.imageScale(.medium)') == 2 and '.contentShape(Rectangle())' not in adj,
         'adjustment:semantic-symbols-visible-44-no-conflicting-inner-shape')
    need('if !editing, isActive() { commit() }' in adj and 'if !dragging { commit() }' in adj,
         'adjustment:original-slider-release-and-accessible-commit')
    b = member(tools,'private var edgeBar:', 'private var edgeDock:')
    need('Spacer(minLength: 24).accessibilityHidden(true)' in b and 'Text(' not in b and 'Label(' not in b,
         'b:actual-empty-center-original-two-side-controls')
    need(tools.count('.imageScale(.medium)') == 3 and tools.count('.padding(.horizontal, 12).padding(.vertical, 4)') == 4
         and tools.count('.buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent))') == 2
         and '.contentShape(Capsule())' in tools and '.contentShape(Rectangle())' not in tools,
         'abc-tools:shared-sizing-spacing-symbols-visible-surfaces-c-capsule')
    need('RoundedRectangle(cornerRadius: 28' in tools and 'RoundedRectangle(cornerRadius: 16' in tools
         and 'case .direct: floatingCapsule' in tools and 'case .tabs: edgeBar' in tools and 'case .sidebar: edgeDock' in tools,
         'abc:retain-three-recognizable-layouts')
    need('Task {' not in tools and '.task' not in tools and '.animation(' not in tools
         and '@State private var trayExpanded = false' in tools
         and '.allowsHitTesting(visible && state.canInteract).accessibilityHidden(!visible)' in tools,
         'tools:no-new-task-animation-state-machine-or-hit-bypass')
    checks.extend(dock.d1_focus_contracts(s))
    need('case (.clear, .light):' in s['App/AppVisualStyle.swift'] and 'case (.clear, _):' in s['App/AppVisualStyle.swift']
         and 'case (.mist, .light):' in s['App/AppVisualStyle.swift'] and 'case (.mist, _):' in s['App/AppVisualStyle.swift']
         and 'case (.ink, _):' in s['App/AppVisualStyle.swift'] and 'theme == .dark ?' in s['App/Reading/ReaderVisualStyle.swift'],
         'light-dark-three-management-palettes-and-independent-reader-colors-preserved')
    need('reduceMotion ? .opacity :' in shell and '.transaction { if reduceMotion { $0.animation = nil } }' in shell
         and 'let animatePress = isEnabled && !reduceMotion' in style and 'if !animatePress { transaction.animation = nil }' in style,
         'drawer-and-shared-press-reduce-motion-retained')
    need('minimumScaleFactor' not in m and 'fixedSize(horizontal: false, vertical: true)' in m
         and 'if dynamicType.isAccessibilitySize' in settings and 'ViewThatFits(in: .horizontal)' in settings
         and 'ScrollView(.vertical)' in tools, 'dynamic-type:wrapping-stacking-scrolling-not-shrinking')
    need('surfaceInset:' not in footer and '.contentShape(Rectangle())' not in footer
         and footer.count('ReaderCompactButtonStyle(') == 2, 'footer:both-controls-use-shared-boundary-with-original-layout')
    return checks


def negative_controls(sources, before):
    rejected = []
    def reject(name, altered, contract):
        try:
            contract(altered)
        except (AssertionError, ValueError):
            rejected.append(name)
        else:
            raise AssertionError('Accepted negative control: ' + name)
    for p, name in [(STYLE,'old-inset6-visible32'), (MANAGEMENT,'old-menu-implicit-row')]:
        altered = dict(sources); altered[p] = before[p]
        reject(name, altered, source_contracts)
    old_theme = member(before[SETTINGS], '    private func themeButton(', '    private func apply(')
    live_theme = member(sources[SETTINGS], '    private func themeButton(', '    private func apply(')
    altered = dict(sources); altered[SETTINGS] = altered[SETTINGS].replace(live_theme, old_theme, 1)
    reject('old-theme-swatch-only-isolated', altered, source_contracts)
    mutations = [
        ('menu-radius-mismatch',MANAGEMENT,'contentShape(RoundedRectangle(cornerRadius: 12','contentShape(RoundedRectangle(cornerRadius: 8'),
        ('menu-invisible-extra-target',MANAGEMENT,'.contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))',
         '.contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(8)'),
        ('menu-auto-row',MANAGEMENT,'.buttonStyle(.plain)','.buttonStyle(.automatic)'),
        ('style-under44',STYLE,'.frame(minWidth: 44, minHeight: 44)','.frame(minWidth: 32, minHeight: 32)'),
        ('style-hit-shape-mismatch',STYLE,'contentShape(RoundedRectangle(cornerRadius: 10','contentShape(RoundedRectangle(cornerRadius: 2'),
        ('b-fake-center',TOOLS,'Spacer(minLength: 24).accessibilityHidden(true)','Text("chapter")'),
        ('c-lost-memory-sync',TOOLS,'        rememberFocus(target)\n',''),
        ('c-unavailable-expand-focus',TOOLS,'restoreFocus(to: model.chapterTotal > 0 ?','restoreFocus(to: true ?'),
        ('lost-dark-palette','App/AppVisualStyle.swift','case (.mist, _):','case (.mist, .light):'),
        ('theme-missing-reduce-motion',SETTINGS,'let selectionAnimation = reduceMotion ? nil : ReaderMotion.selectionFeedback',
         'let selectionAnimation = ReaderMotion.selectionFeedback'),
    ]
    for name,p,old,new in mutations:
        assert old in sources[p], 'Unbound mutation: ' + name
        altered = dict(sources); altered[p] = altered[p].replace(old,new,1)
        reject(name,altered,source_contracts)
    for name,p,old,new in [
        ('import-action-drift',CONTENT,'model.beginFileSelection()','model.cancelImport()'),
        ('layout-persistence-drift',CONTENT,'libraryLayoutRawValue = option.rawValue','libraryLayoutRawValue = "a"'),
        ('busy-gate-drift',CONTENT,' && model.message == nil',''),
        ('settings-commit-drift',SETTINGS,'preferences = value\n        changed()','preferences = value'),
        ('tool-action-drift',TOOLS,'Button { open(panel) }','Button { open(.directory) }'),
        ('footer-action-drift',FOOTER,'Button(action: requestCurrent)','Button(action: loadNext)'),
    ]:
        assert old in sources[p], name
        altered = dict(sources); altered[p] = altered[p].replace(old,new,1)
        reject(name,altered,lambda x: reverse_presentation(x,before))
    return rejected


def protection(baseline, preservation, reconciliation_freeze=None):
    assert baseline['head'] == HEAD and len(baseline['files']) == 238
    changed = [p for p,h in baseline['files'].items() if digest_file(ROOT/p) != h]
    reconciliation = None
    checker_changes = set()
    if reconciliation_freeze is not None:
        start = json.loads(reconciliation_freeze.read_text(encoding='utf8'))
        checker_changes = {'scripts/'+name+'.py' for name in (
            'check_library_navigation_schemes', 'check_reader_dock_schemes',
            'check_navigation_panel_layout', 'check_ui_motion_polish', 'check_app_visual_foundation')}
        allowed = checker_changes | set(NEW)
        assert start['kind'] == 'CHECKER_RECONCILIATION_START' and start['head'] == HEAD
        assert start['index'] == baseline['index']
        # The previous 53 exact presentation fragments/42 contracts/19 negatives
        # are unchanged. This later authorization permits checker/docs only.
        assert all(start['files'][p] == baseline['files'][p] for p in checker_changes)
        drift = [p for p,h in start['files'].items() if digest_file(ROOT/p) != h]
        assert set(drift) == allowed, 'Reconciliation changed protected start bytes: '+str(drift)
        assert all(digest_file(ROOT/p) == start['files'][p] for p in PATCHES), 'App UI drift since reconciliation start'
        reconciliation = dict(frozen=len(start['files']), changed=drift,
                              protected_unchanged=len(start['files'])-len(drift), app_eight_byte_identical=True)
    assert set(changed) == set(PATCHES) | checker_changes, changed
    assert git('rev-parse','HEAD').decode().strip() == HEAD
    assert digest_file(ROOT/'.git/index') == baseline['index'] and not git('diff','--cached','--binary')
    expected = set(baseline['status_porcelain_v1']) | {' M '+p for p in PATCHES} | {'?? '+p for p in NEW}
    expected |= {' M '+p for p in checker_changes}
    assert set(git('status','--short','--untracked-files=all').decode('utf8').splitlines()) == expected
    supplemental = json.loads(preservation.read_text(encoding='utf8'))
    current_extra = {p.relative_to(ROOT).as_posix() for p in (ROOT/'scripts').rglob('*.pyc')}
    current_extra |= {p.relative_to(ROOT).as_posix() for p in (ROOT/'artifacts').rglob('*.ipa')}
    assert current_extra == set(supplemental), 'IPA/pycache path delta'
    assert all(digest_file(ROOT/p) == h for p,h in supplemental.items()), 'IPA/pycache hash delta'
    return dict(frozen=238, changed=changed, protected_unchanged=238-len(changed), head_index_unchanged=True,
                staged_diff_bytes=0, supplemental_ipa_pycache_unchanged=len(supplemental),
                protected_paths=[p for p in baseline['files'] if p not in changed], reconciliation=reconciliation)


def historical_main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--historical-baseline', '--baseline', dest='baseline', type=Path, default=BASELINE)
    parser.add_argument('--preservation', type=Path, default=ROOT / 'artifacts/ui-inspection-20261031/IMPLEMENTATION20261031T064231915687Z/supplemental-preservation-before.json')
    parser.add_argument('--reconciliation-freeze', type=Path,
                        help='Explicit later checker-only start freeze; never relaxes the 53 UI fragments')
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text(encoding='utf8'))
    before = load_before(baseline)
    paths = set(PATCHES) | {dock.SCREEN, 'App/AppVisualStyle.swift', 'App/Reading/ReaderVisualStyle.swift',
                           'App/Reading/ReaderDirectorySheet.swift'}
    sources = {p:(ROOT/p).read_text(encoding='utf8') for p in paths}
    restored = reverse_presentation(sources,before)
    checks = source_contracts(sources)
    rejected = negative_controls(sources,before)
    inv = inventory.validate_source()
    assert inv['selected'] == 138 and inv['all_declared'] == 139
    print(json.dumps(dict(kind='OFFLINE_SOURCE_AND_HASH_NOT_SWIFT_OR_UIKIT', checks=checks,
        negative_controls_rejected=rejected, exact_presentation_fragments=sum(map(len,PATCHES.values())),
        exact_remaining_source_equality=[p for p in before if restored[p] == before[p]],
        d1_specifications=dock.d1_focus_specifications(sources), protection=protection(baseline,args.preservation,args.reconciliation_freeze),
        inventory=inv, native_compilations=0, native_executions=0, touch_tests=0, pixel_renders=0),ensure_ascii=False,indent=2))



# Current soft-editorial phase. The frozen fdbdca/53-fragment functions above
# remain historical, with their original SHA/hash expectations unmodified.
CURRENT_HEAD = '7d55aa5795abcb692af50f37c54c3a51bd841ac3'
CURRENT_EVIDENCE = ROOT / 'artifacts/soft-editorial-ui-local-20261031T085953070749Z'
CURRENT_MANIFEST_SHA = 'ebe1237e77c9dc61237c6ddc5fc6a50749298247a3394575f0134a3ef56dc031'
F1_EVIDENCE = CURRENT_EVIDENCE / 'F1_REPAIR20261031T092542046883Z'
F1_MOVES_SHA = '9d876d6e3ab5df6e951a79e2527b0a243f30b9d756fc70135c1178e778a8e86d'


def _press_block(text, marker):
    """Bounded paint/label blocks below contain no literal or comment braces."""
    start = text.index(marker); opening = text.index('{', start); depth = 0
    for i in range(opening, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0: return text[start:i+1]
    raise AssertionError('Unclosed source paint block: '+marker)


def f1_restore_paint(path, live):
    """An extra four exact paint moves, then the unchanged original 122 ledger."""
    data = (F1_EVIDENCE/'f1-paint-moves-v2.json').read_bytes()
    assert hashlib.sha256(data).hexdigest() == F1_MOVES_SHA, 'F1 move ledger drift'
    entry = json.loads(data)['files'].get(path)
    if entry is None: return live, 0
    before = (F1_EVIDENCE/'before'/path).read_text(encoding='utf8')
    assert hashlib.sha256(before.encode()).hexdigest() == entry['before_sha256']
    a=before.splitlines(keepends=True); b=live.splitlines(keepends=True)
    actual=[(i,j,k,l) for op,i,j,k,l in difflib.SequenceMatcher(None,a,b,autojunk=False).get_opcodes() if op!='equal']
    assert actual == [tuple(x['old']+x['new']) for x in entry['ops']], 'Outside F1 base move: '+path
    for x in entry['ops']:
        i,j=x['old']; k,l=x['new']; u,v=x['anchor_lines']
        assert hashlib.sha256(''.join(a[i:j]).encode()).hexdigest()==x['old_sha256']
        assert hashlib.sha256(''.join(b[k:l]).encode()).hexdigest()==x['new_sha256']
        assert live.count(x['anchor'])==1 and ''.join(b[u:v])==x['anchor'], 'F1 nonunique paint anchor'
    for x in reversed(entry['ops']):
        i,j=x['old']; k,l=x['new']; b[k:l]=a[i:j]
    assert ''.join(b)==before
    return before,len(entry['ops'])


def f1_press_layers(s, callers=('collapsed','preset')):
    """Source composition contract, NOT a Swift renderer or touch measurement.

    SwiftUI .background order: later caller base behind styled label, style's
    pressed background behind label contents. Opaque paint INSIDE that label
    would mask the pressed layer. Do not repair that with a foreground veil.
    """
    import re
    style=s[STYLE]; checks=[]; rows=[]
    def need(ok,name):
        assert ok, name
        checks.append('F1:'+name)
    need(style.count('.background {')==1,'style-feedback-is-background-not-content-veil')
    paint=_press_block(style,'.background {')
    need(style.count('.background {')==1 and '.overlay' not in style and
         'return configuration.label' in style and '.foregroundStyle(tint)' in style and
         '.frame(minWidth: 44, minHeight: 44)' in style and
         '.contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))' in style and
         'let pressed = isEnabled && configuration.isPressed' in style and
         'let animatePress = isEnabled && !reduceMotion' in style and
         '.opacity(isEnabled ? 1 : 0.4)' in style, 'unchanged-inbounds-style-no-foreground-veil')
    need(paint.count('.animation(')==1 and '.allowsHitTesting(false)' in paint and
         '.animation(animatePress ? ReaderMotion.pressFeedback : nil,' in paint and
         'if !animatePress { transaction.animation = nil }' in paint and
         '.animation(' not in style.replace(paint,'',1), 'only-press-decoration-animates-disabled-RM-gated')
    amount=re.search(r'\.fill\(tint\.opacity\(pressed \? ([0-9.]+) : \(role == \.primary \? ([0-9.]+) : (0)\)\)\)',paint)
    need(amount is not None,'bound-source-quiet-primary-alpha-branches')
    pressed_alpha=float(amount.group(1)); primary_alpha=float(amount.group(2))
    need(pressed_alpha==0.10 and primary_alpha==0.06,'original-press-and-steady-alpha-unchanged')
    scenarios=[]
    if 'collapsed' in callers:
        card=member(s[TOOLS],'                Button {','    private var collapseButton:')
        label=_press_block(card,'} label: {')
        base='.background(appearance.fill.opacity(model.exitSaveFailed || !state.canInteract ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 28, style: .continuous))'
        need('.background' not in label and '.overlay' not in label,'collapsed-label-has-no-base-occluding-press')
        need(card.count(base)==1 and card.index('.buttonStyle(')<card.index(base) and
             '.buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground, cornerRadius: 28))' in card and
             '.contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))' in label and
             '.frame(minWidth: 44, minHeight: metrics.controlHeight)' in label,
             'collapsed-content-front-press-middle-base-back-matching28')
        appearance=s['App/Reading/ReaderToolAppearance.swift']
        need('surface.opacity(reduceTransparency ? 1 : 0.97)' in appearance,
             'collapsed-opaque-reduce-transparency-source-preserved')
        scenarios += [('collapsed-reduce-transparency',1.0),('collapsed-standard',0.97)]
    if 'preset' in callers:
        card=member(s[SETTINGS],'private func presetButton','private var restoreTypographyButton')
        label=_press_block(card,'} label: {'); base=_press_block(card,'.background {')
        need('.background' not in label and '.overlay' not in label,'preset-label-has-no-selected-base-occluding-press')
        need(card.index('.buttonStyle(')<card.index('.background {') and
             'RoundedRectangle(cornerRadius: 16, style: .continuous)' in base and
             '.fill(selected ? appearance.surface : .clear)' in base and '.allowsHitTesting(false)' in base and
             '.contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))' in label and
             '.frame(minWidth: 84, maxWidth: .infinity, minHeight: 68)' in label,
             'preset-content-front-press-middle-selected-base-back-matching16')
        need('.opacity(isActive() ? 1 : 0.4)' in base,'preset-base-preserves-original-disabled-alpha')
        need('.animation(selectionAnimation, value: selectionMotionKey)' in base and
             'if reduceMotion { transaction.animation = nil }' in base and
             'let selectionAnimation = reduceMotion ? nil : ReaderMotion.selectionFeedback' in card and
             '.animation(' not in card.replace(base,'',1) and 'checkmark' not in card and
             'selected ? .semibold : .regular' in label,'preset-only-base-selection-animates-original-single-state-marker')
        scenarios += [('preset-selected',1.0),('preset-unselected',0.0)]
    for name,base_alpha in scenarios:
        for enabled in (False,True):
            for pressed in (False,True):
                for reduced_motion in (False,True):
                    alpha=pressed_alpha if enabled and pressed else 0.0
                    assert not (not enabled and alpha), 'Disabled source branch must suppress press'
                    rows.append(dict(scenario=name,base_alpha=base_alpha,enabled=enabled,pressed=pressed,
                                     reduce_motion=reduced_motion,press_alpha_in_front_of_base=alpha,
                                     base_alpha_after_disabled=base_alpha*(1.0 if enabled else 0.4),
                                     press_animation_enabled=enabled and not reduced_motion,
                                     content_in_front=True,layer_order_front_to_back=['content','style press','caller base']))
    return dict(kind='SOURCE_LAYER_ORDER_NOT_SWIFT_UI_EXECUTION',checks=checks,source_derived_rows=rows)


def f1_press_negatives(s):
    # Directly exercise the saved REAL pre-F1 combinations, not invented stand-ins.
    frozen=json.loads((F1_EVIDENCE/'start-freeze.json').read_text(encoding='utf8'))
    old={}
    for p in (STYLE,TOOLS,SETTINGS):
        raw=(F1_EVIDENCE/'before'/p).read_bytes()
        assert digest_bytes(raw)==frozen['files'][p], 'F1 snapshot not original bytes'
        old[p]=raw.decode('utf8')
    cases=[('saved-real-F1-both-callers',dict(old)),
           ('saved-real-F1-opaque-C', {STYLE:old[STYLE],TOOLS:old[TOOLS]}),
           ('saved-real-F1-selected-preset', {STYLE:old[STYLE],SETTINGS:old[SETTINGS]}),
           ('press-veil-over-foreground',{STYLE:s[STYLE].replace('.background {','.overlay {',1)})]
    rejected=[]
    for name,delta in cases:
        altered=dict(s);altered.update(delta)
        try: f1_press_layers(altered)
        except AssertionError as error: rejected.append(dict(name=name,rejected_by=str(error)))
        else: raise AssertionError('Accepted F1 composition: '+name)
    return rejected


def current_exact(sources):
    """Reverse individually pinned paint fragments with unique live anchors.

    No modifier family or whole member is erased. Baseline blobs must match
    actual pre-edit hashes. This function does not run any other check suite.
    """
    base = json.loads((CURRENT_EVIDENCE/'preedit.json').read_text(encoding='utf8'))
    data = (CURRENT_EVIDENCE/'paint-fragments-v2.json').read_bytes()
    assert hashlib.sha256(data).hexdigest() == CURRENT_MANIFEST_SHA, 'Paint manifest drift'
    manifest = json.loads(data)
    assert base['head'] == manifest['head'] == CURRENT_HEAD
    results = []
    for p, live in sources.items():
        if p not in base['production']:
            continue
        live,f1_moves=f1_restore_paint(p,live)
        raw = git('show', CURRENT_HEAD+':'+p)
        assert digest_bytes(raw) == base['files'][p], 'Not actual pre-edit baseline: '+p
        before = raw.decode('utf8'); a = before.splitlines(keepends=True); b = live.splitlines(keepends=True)
        actual = [(i,j,k,l) for op,i,j,k,l in difflib.SequenceMatcher(None,a,b,autojunk=False).get_opcodes() if op != 'equal']
        patches = manifest['files'][p]
        assert actual == [tuple(x['old']+x['new']) for x in patches], 'Non-paint delta: '+p
        for x in patches:
            i,j = x['old']; k,l = x['new']; u,v = x['anchor_lines']
            assert hashlib.sha256(''.join(a[i:j]).encode()).hexdigest() == x['old_sha256']
            assert hashlib.sha256(''.join(b[k:l]).encode()).hexdigest() == x['new_sha256'], p
            assert live.count(x['anchor']) == 1 and ''.join(b[u:v]) == x['anchor'], 'Nonunique/unbound paint anchor: '+p
        for x in reversed(patches):
            i,j=x['old']; k,l=x['new']; b[k:l]=a[i:j]
        assert ''.join(b) == before, 'Non-paint source drift: '+p
        results.append(dict(path=p,exact_fragments=len(patches),f1_extra_paint_moves=f1_moves,remaining_text_equal=True))
    return results


def current_contracts(s):
    checks=[]
    def need(ok,name):
        assert ok, name
        checks.append(name)
    c,m,t,style,settings,adjust,footer = (s[p] for p in (CONTENT,MANAGEMENT,TOOLS,STYLE,SETTINGS,ADJUSTMENT,FOOTER))
    for p in json.loads((CURRENT_EVIDENCE/'preedit.json').read_text(encoding='utf8'))['production']:
        code=lexical.strip_swift_comments_and_strings(s[p]); lexical.check_balanced_delimiters(p,code)
        need(not any(x in code for x in ('@Observable','import Observation','import SwiftData','symbolEffect','minimumScaleFactor','zIndex','DragGesture','onTapGesture','Task.sleep','asyncAfter')),
             p+':lexical-ios16-no-new-gesture-heavywork')
    need('var role: ReaderControlRole = .quiet' in style and 'case quiet, primary' in style and
         'surfaceInset' not in style and '.stroke' not in style and '.frame(minWidth: 44, minHeight: 44)' in style,
         'roles:quiet-default-primary-opt-in-geometry44-not-paint44')
    need(style.count('RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)') == 2 and
         '.fill(tint.opacity(pressed ? 0.10 : (role == .primary ? 0.06 : 0)))' in style and
         '.padding(' not in style and 'let pressed = isEnabled && configuration.isPressed' in style and
         'let animatePress = isEnabled && !reduceMotion' in style and 'if !animatePress { transaction.animation = nil }' in style,
         'roles:matching-local-pressed-shape-no-invisible-expansion-disabled-reduce-motion')
    need(style.index('.background {') < style.index('.animation(') and style.count('.animation(')==1 and
         '.animation(' not in style[:style.index('.background {')], 'press:only-decoration-not-label-geometry')
    app=s['App/AppVisualStyle.swift']
    need('var surface: Color = .clear' in app and 'foreground.opacity(pressed ? 0.08 : 0)' in app and
         'if !animatePress { $0.animation = nil }' in app and '.stroke' not in app,
         'management:quiet-base-and-local-fill-feedback')
    option=member(m,'private func optionLabel(','\n@MainActor\nstruct LibraryLicenseView')
    need(m.count('AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 0)')==2 and
         m.count('EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)')==2 and
         m.count('.listRowBackground(appearance.groupSurface)')==1 and
         'minWidth: 44, maxWidth: .infinity, minHeight: 64' in option and '.contentShape(Rectangle())' in option and
         '.padding(' not in option[option.index('.contentShape('):] and '.background' not in option,
         'menus:one-group-inbounds-rows-no-auto-row-or-per-row-card')
    need('Text(value)' in option and 'chevron.down' in option and 'ViewThatFits(in: .horizontal)' in option and
         'if !asMenu {' in m and '外观仅改变管理界面，不改变阅读背景。' in m,
         'menus:left-title-right-value-indicator-group-explanation-narrow-fallback')
    need('model.beginFileSelection()' in c and '.accessibilityLabel("导入书籍")' in c and
         'AppControlButtonStyle(foreground: appearance.accent, surface: appearance.accent.opacity(0.12))' in c and '.stroke' not in c,
         'import:single-soft-primary-full-ax-original-action')
    shelf=s['App/Library/LibraryShelfContent.swift']
    need('ForEach(books) { book in' in shelf and not any(x in shelf for x in ('enumerated(','.map(','sorted(','firstIndex(')) and
         'Button { onOpenBook(book) }' in shelf and 'book.lastReadAt' in shelf,
         'shelf:original-id-order-real-metadata-no-fake-ordinal-or-progress')
    need('showsShelfTitle: layout == .direct' in shelf and 'Text("\\(bookCount) 本")' in s['App/Library/LibraryHeaderView.swift'],
         'masthead:real-count-abc-title-hierarchy')
    need('shape.fill(item == section ? appearance.softSelection : .clear)' in s[SHELL] and
         '.allowsHitTesting(!drawerPresented)' in s[SHELL] and '.accessibilityHidden(drawerPresented)' in s[SHELL],
         'drawer:only-current-band-original-background-inert')
    b=member(t,'private var edgeBar:','private var edgeDock:')
    need('Spacer(minLength: 24).accessibilityHidden(true)' in b and 'Text(' not in b and 'Label(' not in b and 'Button(' not in b,
         'b:real-empty-center-no-middle-ui')
    need(t.count('.shadow(')==3 and '.stroke' not in t and '.animation(' not in t and '.task' not in t and 'Task {' not in t,
         'abc:one-soft-group-surface-static-shadow-no-new-work-or-animation')
    checks.extend(dock.d1_focus_contracts(s))
    for name,begin,end in [('preset','private func presetButton','private var restoreTypographyButton'),('theme','private func themeButton','private func apply(')]:
        card=member(settings,begin,end)
        selected_base=_press_block(card,'.background {')
        no_label_animation=('.animation(' not in card.replace(selected_base,'',1)) if name=='preset' else ('.animation(' not in card[card.index('.contentShape('):])
        need('.contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))' in card and
             '.stroke' not in card and '.accessibilityAddTraits(selected ? .isSelected : [])' in card and
             no_label_animation, name+':whole-option-selected-ax-quiet-hit-bounds')
    need('selected ? .semibold : .regular' in settings and 'Image(systemName: "checkmark.circle.fill")' not in settings and
         settings.count('Image(systemName: "checkmark")')==1 and
         '.background(appearance.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))' in settings,
         'choices:single-preset-selection-group-and-one-theme-check-no-triple-feedback')
    need('if !editing, isActive() { commit() }' in adjust and 'if !dragging { commit() }' in adjust and
         adjust.count('.frame(minWidth: 44, minHeight: 44)')==2 and 'HStack(alignment: .center, spacing: 0)' in adjust,
         'adjustment:nonoverlapping44-targets-value-group-release-commit')
    preview=s['App/Reading/ReaderTypographyPreview.swift']
    need('.font(.custom("PingFangSC-Regular", fixedSize: CGFloat(preferences.fontSize)))' in preview and
         '.lineSpacing(CGFloat(preferences.lineSpacing))' in preview and 'preferences.theme.background' in preview and
         '晚风翻过书页，\\n故事在此刻继续。' in preview,
         'preview:original-sample-and-real-font-spacing-theme-not-shrunk-to-fit')
    need('Button(action: requestCurrent)' in footer and 'action: loadPrevious' in footer and 'action: loadNext' in footer and
         'Image(systemName: "hourglass")' in footer and '.frame(width: Self.loadingSlotWidth, height: 1)' in footer and
         footer.count('ReaderCompactButtonStyle(tint: appearance.foreground)')==2,
         'directory:quiet-group-real-actions-static-balanced-range')
    row=s['App/Reading/ReaderDirectoryChapterRow.swift'];sheet=s['App/Reading/ReaderDirectorySheet.swift']
    need('String(repeating: "8", count: columnDigits)' in row and '.hidden()' in row and
         '.font(.system(.body, design: .serif))' in row and 'Capsule().fill(appearance.accent)' not in row and
         '.listRowBackground(current ? appearance.selection : appearance.surface)' in sheet,
         'directory:measured-ordinal-current-soft-band-not-line-frame-stack')
    checks.extend(f1_press_layers(s)['checks'])
    return checks


def current_negatives(s):
    cases=[
        ('quiet-permanent-fill',STYLE,'role == .primary ? 0.06 : 0)))','role == .primary ? 0.06 : 0.08)))'),
        ('under44',STYLE,'.frame(minWidth: 44, minHeight: 44)','.frame(minWidth: 32, minHeight: 32)'),
        ('wrong-role-shape',STYLE,'contentShape(RoundedRectangle(cornerRadius: cornerRadius','contentShape(RoundedRectangle(cornerRadius: 2'),
        ('label-animation',STYLE,'.foregroundStyle(tint)','.foregroundStyle(tint).animation(.linear, value: pressed)'),
        ('disabled-motion',STYLE,'isEnabled && !reduceMotion','true'),
        ('menu-row-expanded',MANAGEMENT,'.contentShape(Rectangle())','.contentShape(Rectangle()).padding(8)'),
        ('menu-auto',MANAGEMENT,'AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 0)','.automatic'),
        ('wrong-import-ax',CONTENT,'.accessibilityLabel("导入书籍")','.accessibilityLabel("打开")'),
        ('b-center-ui',TOOLS,'Spacer(minLength: 24).accessibilityHidden(true)','Text("chapter")'),
        ('c-focus-memory',TOOLS,'        rememberFocus(target)\n',''),
        ('new-tool-task',TOOLS,'.foregroundStyle(appearance.foreground).tint(appearance.accent)', '.foregroundStyle(appearance.foreground).tint(appearance.accent).task { await Task.yield() }'),
        ('slider-every-drag',ADJUSTMENT,'if !dragging { commit() }','commit()'),
        ('theme-outline',SETTINGS,'.fill(selected ? appearance.selection : .clear)','.stroke(appearance.accent)'),
        ('wrong-preview-size','App/Reading/ReaderTypographyPreview.swift','CGFloat(preferences.fontSize)','CGFloat(14)'),
    ]
    rejected=[]
    for name,p,a,b in cases:
        assert a in s[p], 'Unbound negative '+name
        altered=dict(s);altered[p]=altered[p].replace(a,b,1)
        try: current_contracts(altered)
        except (AssertionError,ValueError): rejected.append(name)
        else: raise AssertionError('Accepted current negative '+name)
    # These exact patch negatives protect full business functions/AX/lifecycle,
    # not just the presence of tokens elsewhere in a source file.
    for name,p,a,b in [
        ('wrong-action',CONTENT,'model.beginFileSelection()','model.cancelImport()'),
        ('persist-confusion',CONTENT,'libraryLayoutRawValue = option.rawValue','appAppearanceRawValue = option.rawValue'),
        ('busy-bypass',CONTENT,' && model.message == nil',''),
        ('viewport-hook','App/Reading/ReaderScreen.swift','onAnchor: model.visibleChanged','onAnchor: model.scrollingEnded'),
        ('exit-save','App/Reading/ReaderScreen.swift','succeeded = await model.close()','succeeded = true'),
        ('finish-commit',SETTINGS,'commitDraft(); close()','close()'),
    ]:
        assert a in s[p],name
        altered={p:s[p].replace(a,b,1)}
        try: current_exact(altered)
        except AssertionError: rejected.append(name)
        else: raise AssertionError('Accepted exact delta negative '+name)
    rejected.extend(x['name'] for x in f1_press_negatives(s))
    return rejected


def current_protection():
    b=json.loads((CURRENT_EVIDENCE/'preedit.json').read_text(encoding='utf8'))
    changed=[p for p,h in b['files'].items() if digest_file(ROOT/p)!=h]
    assert set(changed)<=set(b['allowed']) and git('rev-parse','HEAD').decode().strip()==CURRENT_HEAD
    assert digest_file(ROOT/'.git/index')==b['index'] and not git('diff','--cached','--binary')
    expected=set(b['status'])|{' M '+p for p in changed}|{'?? '+b['new_doc']}
    assert set(git('status','--short','--untracked-files=all').decode('utf8').splitlines())==expected
    pycache={p.relative_to(ROOT).as_posix() for p in (ROOT/'scripts').rglob('*.pyc')}
    assert pycache==set(b['groups']['pycache'])
    return dict(frozen=len(b['files']),changed=changed,protected_unchanged=len(b['files'])-len(changed),head_index_staged_unchanged=True,
                groups={name:dict(total=len(paths),unchanged=sum(p not in changed for p in paths)) for name,paths in b['groups'].items()})

# This release is a new explicit phase, not a re-recording of the historical
# local/index/HEAD freeze. All current UI source/negative contracts still run.
RELEASE_EVIDENCE = ROOT / 'artifacts/soft-editorial-device-buildonly-20261031T094514424891Z'
RELEASE_FREEZE_SHA = '454e55017f41d36e08aca501d3254e42532d1a1617cc032c0730b078c0b7c562'
RELEASE_SCOPE = ROOT / 'artifacts/soft-editorial-native-release-scope-20261031T094114523226Z/whitelist.json'
RELEASE_SCOPE_SHA = '76cac976ac55c5938866f82638821ee2920e6af2a62abac433d55a750e9cb246'
RELEASE_MUTABLE = {'.github/workflows/ios-build.yml','scripts/check_ui_control_cohesion.py','docs/SOFT_EDITORIAL_UI_LOCAL.md'}


def release_check(start, authority, receipt, observed, stage, source_sha=None):
    """Pure phase validator used by actual CLI and bounded in-memory negatives.

    Inputs are read by release_protection from pinned local evidence, not from
    caller-supplied arbitrary metadata. Git facts come from real git plumbing.
    """
    import re
    expected={x['path'] for x in authority['paths']}
    assert authority['head']==start['head']==receipt['parent']==CURRENT_HEAD, 'release parent mismatch'
    assert start['kind']=='APPROVED_SOFT_EDITORIAL_RELEASE31_START'
    assert receipt['schema']=='SOFT_EDITORIAL_RELEASE31_RECEIPT_V1'
    assert len(expected)==authority['count']==31 and expected==set(start['paths31'])==set(receipt['paths31']), 'exact31 paths required'
    assert len(receipt['paths31'])==31 and set(receipt['candidates'])==expected, 'receipt candidate set mismatch'
    assert receipt['start_freeze_sha256']==RELEASE_FREEZE_SHA and receipt['scope_sha256']==RELEASE_SCOPE_SHA
    assert set(start['mutable'])==RELEASE_MUTABLE, 'phase may change only approved adapters'
    assert receipt['f1_closed_hash']==start['closure_hash'] and observed['f1_closed']=='closed', 'F1 closure mismatch'
    assert set(observed['hashes'])==set(start['files']), 'protection path set mismatch'
    assert all(observed['hashes'][p]==h for p,h in start['files'].items() if p not in RELEASE_MUTABLE), 'protected/fixed candidate hash drift'
    for item in authority['paths']:
        p=item['path']
        if p not in RELEASE_MUTABLE:
            assert receipt['candidates'][p]==item['current']==observed['hashes'][p], 'F1 candidate bytes changed: '+p
    assert all(observed['hashes'][p]==h for p,h in receipt['candidates'].items()), 'final31 receipt bytes drift'
    assert observed['branch']=='main' and observed['ordinary_files'], 'wrong branch or symlink'
    assert observed['pycache_paths']==set(start['groups']['pycache']), 'pycache paths changed'
    private={'?? '+p for p in start['groups']['private']}
    if stage=='precommit':
        assert source_sha is None and observed['head']==CURRENT_HEAD and not observed['cached_paths'], 'precommit head/staging mismatch'
        assert observed['index']==start['index'], 'precommit index changed'
        assert observed['status']==set(start['status'])|{' M .github/workflows/ios-build.yml'}, 'precommit status outside scope'
        assert observed['work_paths']==expected-{'docs/SOFT_EDITORIAL_UI_LOCAL.md'}, 'precommit exact tracked diff mismatch'
    elif stage=='staged':
        assert source_sha is None and observed['head']==CURRENT_HEAD, 'staged head changed'
        assert observed['cached_paths']==expected and not observed['work_paths'], 'staged set must be exact31 and worktree clean'
        assert observed['index_blobs']==receipt['candidates'], 'staged blob mismatch'
        status=private|{'A  docs/SOFT_EDITORIAL_UI_LOCAL.md'}|{'M  '+p for p in expected-{'docs/SOFT_EDITORIAL_UI_LOCAL.md'}}
        assert observed['status']==status,'staged status mismatch'
    elif stage=='committed':
        assert source_sha and re.fullmatch('[0-9a-f]{40}',source_sha) and source_sha!=CURRENT_HEAD
        assert observed['head']==source_sha and observed['parents']==[source_sha,CURRENT_HEAD], 'new SHA single-parent mismatch'
        assert observed['commit_paths']==expected and not observed['cached_paths'] and not observed['work_paths'], 'committed exact31/clean mismatch'
        assert observed['commit_blobs']==receipt['candidates'] and observed['untouched_tree_equal'], 'committed or protected tree drift'
        assert observed['status']==private,'committed untracked scope mismatch'
    else:
        raise AssertionError('Unknown release stage')
    return dict(kind='EXPLICIT_RELEASE31_PROTECTION_NOT_OLD_LOCAL_FREEZE_PASS',stage=stage,
                head=observed['head'],parent=CURRENT_HEAD,exact_paths=31,production23_f1_hashes_equal=True,
                protected_paths=len(start['files'])-len(RELEASE_MUTABLE),frozen=len(start['files']),
                permitted_adapter_changes=sorted(RELEASE_MUTABLE),old_local_protection='unchanged; not applicable after phase transition')


def release_observe(start, paths31, source_sha=None):
    def text(*args): return git(*args).decode('utf8')
    def blob(spec): return digest_bytes(git('show',spec))
    head=text('rev-parse','HEAD').strip()
    cached=set(text('diff','--cached','--name-only').splitlines())
    work=set(text('diff','--name-only').splitlines())
    committed=source_sha is not None
    closure=json.loads((ROOT/start['closure_path']).read_text(encoding='utf8'))
    observed=dict(hashes={p:digest_file(ROOT/p) for p in start['files']},head=head,
                  index=digest_file(ROOT/'.git/index'),branch=text('branch','--show-current').strip(),
                  status=set(text('status','--short','--untracked-files=all').splitlines()),
                  ordinary_files=all((ROOT/p).is_file() and not (ROOT/p).is_symlink() for p in paths31),
                  pycache_paths={p.relative_to(ROOT).as_posix() for p in (ROOT/'scripts').rglob('*.pyc')},
                  f1_closed=closure['F1'],cached_paths=cached,work_paths=work,
                  index_blobs={p:blob(':'+p) for p in paths31} if cached else {},
                  commit_paths=set(text('diff','--name-only',CURRENT_HEAD,head).splitlines()) if committed else set(),
                  parents=text('rev-list','--parents','-n','1','HEAD').split() if committed else [],
                  commit_blobs={p:blob(head+':'+p) for p in paths31} if committed else {},untouched_tree_equal=False)
    if committed:
        tree=lambda raw:{line.split('\t',1)[1]:line.split('\t',1)[0] for line in raw.splitlines()}
        old=tree(start['tracked_tree']);new=tree(text('ls-tree','-r','--full-tree',head))
        observed['untouched_tree_equal']={p:v for p,v in old.items() if p not in paths31}=={p:v for p,v in new.items() if p not in paths31}
    return observed


def release_protection(receipt_path, receipt_sha256, stage, source_sha=None):
    assert receipt_path.resolve()==(RELEASE_EVIDENCE/'release-receipt.json').resolve(), 'Only explicit trusted batch receipt allowed'
    assert digest_file(receipt_path)['sha256']==receipt_sha256, 'receipt SHA mismatch'
    assert digest_file(RELEASE_EVIDENCE/'start-freeze.json')['sha256']==RELEASE_FREEZE_SHA, 'release start freeze drift'
    assert digest_file(RELEASE_SCOPE)['sha256']==RELEASE_SCOPE_SHA, 'approved scope drift'
    start=json.loads((RELEASE_EVIDENCE/'start-freeze.json').read_text(encoding='utf8'))
    authority=json.loads(RELEASE_SCOPE.read_text(encoding='utf8'))
    receipt=json.loads(receipt_path.read_text(encoding='utf8'))
    assert len(receipt['paths31'])==31 and set(receipt['paths31'])=={x['path'] for x in authority['paths']}, 'Unapproved receipt path'
    assert set(receipt['candidates'])==set(receipt['paths31']) and receipt['parent']==CURRENT_HEAD, 'Unapproved receipt metadata'
    observed=release_observe(start,set(receipt['paths31']),source_sha)
    return release_check(start,authority,receipt,observed,stage,source_sha)



def soft_main(release_args=None):
    b=json.loads((CURRENT_EVIDENCE/'preedit.json').read_text(encoding='utf8'))
    s={p:(ROOT/p).read_text(encoding='utf8') for p in b['production']}
    exact=current_exact(s);checks=current_contracts(s);negatives=current_negatives(s);inv=inventory.validate_source()
    assert inv['selected']==138 and inv['all_declared']==139
    print(json.dumps(dict(kind='SOFT_EDITORIAL_SOURCE_HASH_NOT_NATIVE',source_checks=len(checks),checks=checks,
                         negative_controls_rejected=negatives,exact_paint=exact,
                         protection=(release_protection(**release_args) if release_args else current_protection()),
                         f1_press_layers=f1_press_layers(s),f1_saved_source_rejections=[x for x in negatives if x.startswith('saved-real-F1') or x=='press-veil-over-foreground'],
                         inventory=inv,native_compilations=0,native_executions=0,touch_tests=0),ensure_ascii=False,indent=2))


if __name__ == '__main__':
    import sys
    if '--historical-baseline' in sys.argv or '--baseline' in sys.argv:
        historical_main()
    elif '--release-receipt' in sys.argv:
        parser = argparse.ArgumentParser(description='Explicit release31 phase: full current UI contracts plus pinned release protection')
        parser.add_argument('--release-receipt', type=Path, required=True)
        parser.add_argument('--receipt-sha256', required=True)
        parser.add_argument('--release-stage', choices=('precommit','staged','committed'), required=True)
        parser.add_argument('--source-sha')
        args=parser.parse_args()
        soft_main(dict(receipt_path=args.release_receipt,receipt_sha256=args.receipt_sha256,
                       stage=args.release_stage,source_sha=args.source_sha))
    else:
        assert len(sys.argv)==1, 'Use explicit historical or release parameters; no implicit protection bypass'
        soft_main()
