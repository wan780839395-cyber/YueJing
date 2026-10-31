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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, default=BASELINE)
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


if __name__ == '__main__':
    main()
