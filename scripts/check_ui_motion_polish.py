"""Offline source-contract, in-memory negative-control, and baseline-protection checks
for the bounded reading UI motion & directory loading polish batch.

IMPORTANT BOUNDARY:
- Lexical / structural source checks and in-memory negative controls only.
- NOT a Swift AST parser or compiler, NOT UIKit/SwiftUI runtime execution,
  and NOT a device FPS, frame-time, or touch-latency measurement.
- Native compilations = 0, native test runs = 0, UI touch runs = 0, pixel/FPS runs = 0.
"""
import argparse
import ast
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts"))

import task3_test_inventory as inventory  # noqa: E402

MOTION_WHITELIST_MODIFIED = (
    "App/Reading/ReaderMotion.swift",
    "App/Reading/ReaderSettingsView.swift",
    "App/Reading/ReaderDirectorySheet.swift",
    "App/Reading/ReaderDirectoryFooter.swift",
)

MOTION_WHITELIST_NEW = (
    "scripts/check_ui_motion_polish.py",
    "docs/UI_MOTION_POLISH_LOCAL.md",
)

INSPECTED_SWIFT_FILES = MOTION_WHITELIST_MODIFIED + (
    "App/ContentView.swift",
    "App/Library/LibraryPlannedEntriesView.swift",
    "App/Library/LibraryPlannedNavigation.swift",
    "App/Reading/ReaderCompactButtonStyle.swift",
    "App/Reading/ReaderDirectoryChapterRow.swift",
    "App/Reading/ReaderScreen.swift",
    "App/Reading/ReaderSettingAdjustment.swift",
    "App/Reading/ReaderToolVisibility.swift",
    "App/Reading/ReaderTypographyPreview.swift",
    "Sources/ReaderDomain/ReaderTypographyPreset.swift",
)


def digest_file(path: Path) -> dict:
    """Streamed SHA256 + byte length; never logs or parses protected file contents."""
    h = hashlib.sha256()
    total = 0
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(131072)
            if not chunk:
                break
            h.update(chunk)
            total += len(chunk)
    return {"sha256": h.hexdigest(), "bytes": total}


def strip_swift_comments_and_strings(text: str) -> str:
    """Strip Swift comments and string literals for lexical token/delimiter checks."""
    out = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            nl = text.find("\n", i)
            if nl == -1:
                break
            out.append("\n")
            i = nl + 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end == -1:
                raise ValueError("Unclosed block comment")
            out.append(" ")
            i = end + 2
        elif text[i] == '"':
            if text.startswith('"""', i):
                end = text.find('"""', i + 3)
                if end == -1:
                    raise ValueError("Unclosed multiline string literal")
                out.append('""')
                i = end + 3
            else:
                i += 1
                while i < n and text[i] != '"':
                    if text[i] == "\\":
                        i += 2
                    else:
                        i += 1
                if i >= n:
                    raise ValueError("Unclosed string literal")
                out.append('""')
                i += 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def check_balanced_delimiters(rel_path: str, code_only: str) -> None:
    pairs = {"}": "{", ")": "(", "]": "["}
    stack = []
    for idx, ch in enumerate(code_only):
        if ch in "{([":
            stack.append((ch, idx))
        elif ch in "})]":
            if not stack or stack[-1][0] != pairs[ch]:
                raise AssertionError(f"{rel_path}: mismatched delimiter {ch!r} at offset {idx}")
            stack.pop()
    if stack:
        raise AssertionError(f"{rel_path}: unclosed delimiter {stack[-1][0]!r}")


def load_live_sources() -> dict[str, str]:
    return {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in INSPECTED_SWIFT_FILES}


def verify_source_contracts(sources: dict[str, str]) -> list[str]:
    checks: list[str] = []

    def require(condition: bool, name: str) -> None:
        if not condition:
            raise AssertionError("Motion contract failed: " + name)
        checks.append(name)

    stripped = {rel: strip_swift_comments_and_strings(text) for rel, text in sources.items()}

    # 1. Lexical balance & iOS 16.6 / Swift 6.0 compatibility across all 4 touched files.
    forbidden_modern_or_heavy = (
        ".snappy",
        ".smooth",
        ".bouncy",
        "symbolEffect",
        "phaseAnimator",
        "keyframeAnimator",
        "@Animatable",
        "@Observable",
        "import Observation",
        "import SwiftData",
        "navigationDestination(item:",
        "ViewInspector",
        ".blur(",
        ".drawingGroup(",
        ".compositingGroup(",
        "asyncAfter",
        "Task.sleep",
        "Timer",
        "repeatForever",
        ".spring(",
        "interpolatingSpring",
        "withAnimation",
    )
    for rel in MOTION_WHITELIST_MODIFIED:
        check_balanced_delimiters(rel, stripped[rel])
        for token in forbidden_modern_or_heavy:
            require(token not in stripped[rel], f"{rel}:no-{token}")
    checks.append("four-motion-files-balanced-and-ios16-clean")

    # 2. ReaderMotion.swift design tokens.
    motion = sources["App/Reading/ReaderMotion.swift"]
    require("static let toolVisibilityDuration: Double = 0.16" in motion, "motion:toolVisibilityDuration-0.16")
    require("static let selectionFeedbackDuration: Double = 0.14" in motion, "motion:selectionFeedbackDuration-0.14")
    require("static let pressFeedbackDuration: Double = 0.10" in motion, "motion:pressFeedbackDuration-0.10")
    require("static let hiddenTravel: CGFloat = 6" in motion, "motion:hiddenTravel-6-retained")
    require("static var toolVisibility: Animation { .easeOut(duration: toolVisibilityDuration) }" in motion,
            "motion:toolVisibility-easeOut")
    require("static var selectionFeedback: Animation { .easeOut(duration: selectionFeedbackDuration) }" in motion,
            "motion:selectionFeedback-easeOut")
    require("static var pressFeedback: Animation { .easeOut(duration: pressFeedbackDuration) }" in motion,
            "motion:pressFeedback-easeOut")

    # 3. ReaderSettingsView.swift decorative-only selection feedback & preserved business/AX contracts.
    settings = sources["App/Reading/ReaderSettingsView.swift"]
    settings_code = stripped["App/Reading/ReaderSettingsView.swift"]
    require("@Environment(\\.accessibilityReduceMotion) private var reduceMotion" in settings,
            "settings:reduceMotion-environment")
    require(settings_code.count('.animation(') == 3,
            'settings:three-local-animations-no-container-animation')
    require(settings.count('.animation(selectionAnimation, value: selectionMotionKey)') == 3,
            'settings:all-three-animations-use-reduce-motion-token')
    require(settings.count("let selectionMotionKey = reduceMotion ? 0 : (selected ? 1 : 2)") == 2,
            "settings:preset-and-theme-reduceMotion-value-key")
    require(settings.count("let selectionAnimation = reduceMotion ? nil : ReaderMotion.selectionFeedback") == 2,
            "settings:preset-and-theme-reduceMotion-nil-animation")
    require(settings.count('if reduceMotion { transaction.animation = nil }') == 3,
            'settings:three-decoration-transactions-clear-reduce-motion')

    preset_fn = settings[settings.index("private func presetButton"):settings.index("private var restoreTypographyButton")]
    theme_fn = settings[settings.index("private func themeButton"):settings.index("private func apply(")]

    require('if selected' not in preset_fn+theme_fn and 'checkmark' not in preset_fn and
            theme_fn.count('.opacity(selected ? 1 : 0)') == 1 and
            theme_fn.count('Image(systemName: "checkmark")') == 1 and
            theme_fn.count('.accessibilityHidden(true)') == 1,
            'settings:one-stable-theme-check-no-preset-badge-stack')
    shape = 'RoundedRectangle(cornerRadius: 16, style: .continuous)'
    hit = '.contentShape('+shape+')'
    for name, card in [('preset', preset_fn), ('theme', theme_fn)]:
        require(hit in card, 'settings:'+name+'-whole-option-hit-shape')
        if name == 'preset':
            from check_ui_control_cohesion import _press_block
            paint = _press_block(card, '.background {')
            head = card[:card.index(paint)]
            tail = card[card.index(paint)+len(paint):]
            require(card.index(hit) < card.index('.buttonStyle(') < card.index(paint),
                    'settings:preset-press-in-front-of-selected-base')
        else:
            paint = card[card.index('.background {'):card.index(hit)]
            head = card[:card.index('.background {')]
            tail = card[card.index(hit):]
        require(shape in paint and '.fill(selected ?' in paint and '.stroke' not in paint and
                paint.count('.animation(selectionAnimation, value: selectionMotionKey)') == (1 if name == 'preset' else 2) and
                paint.count('.allowsHitTesting(false)') == (1 if name == 'preset' else 2),
                'settings:'+name+'-soft-paint-animations-decoration-only')
        require('.animation(' not in head+tail and '.inset(' not in card and '.clipShape(' not in card and
                '.frame(minWidth: 84, maxWidth: .infinity, minHeight:' in head,
                'settings:'+name+'-no-glyph-label-frame-action-animation')
    require(theme_fn.index('Text(theme.title)') < theme_fn.index('.frame(minWidth: 84') < theme_fn.index('.background {'),
            'settings:theme-title-in-whole-option')

    # Preserved settings submission, isolation, ranges, and AX contracts.
    commit_fn = settings[settings.index("private func apply("):]
    require("guard isActive() else { return }" in theme_fn[:theme_fn.index("} label: {")]
            and commit_fn.count("guard isActive() else { return }") == 3,
            "settings:all-four-mutation-entry-points-retain-isActive-guard")
    require("let value = draft.validated\n        guard value != preferences else { return }\n        preferences = value\n        changed()" in commit_fn,
            "settings:commitDraft-validated-equality-and-changed-chain-intact")
    require("draft = preset.applying(to: draft); commitDraft()" in commit_fn,
            "settings:preset-apply-chain-intact")
    require("range: 14...36" in settings and "range: 0...20" in settings
            and '.confirmationDialog("恢复默认排版？", isPresented: $showRestore' in settings
            and 'Button("恢复字号与行距") { apply(.standard) }' in settings,
            "settings:ranges-and-restore-confirmation-intact")
    require(settings.count('.accessibilityValue(selected ? "已选择" : "未选择")') == 2
            and settings.count(".accessibilityAddTraits(selected ? .isSelected : [])") == 2,
            "settings:selected-accessibility-value-and-trait-intact")

    # 4. Protected slider, preview, and domain preset isolation contracts.
    adj = sources["App/Reading/ReaderSettingAdjustment.swift"]
    preview = sources["App/Reading/ReaderTypographyPreview.swift"]
    preset_domain = sources["Sources/ReaderDomain/ReaderTypographyPreset.swift"]
    require(".animation(" not in stripped["App/Reading/ReaderSettingAdjustment.swift"]
            and "withAnimation" not in stripped["App/Reading/ReaderSettingAdjustment.swift"],
            "adjustment:no-slider-or-value-animation")
    require("dragging = editing" in adj
            and "if !editing, isActive() { commit() }" in adj
            and "if !dragging { commit() }" in adj,
            "adjustment:slider-release-to-apply-not-per-drag-step")
    require(".animation(" not in stripped["App/Reading/ReaderTypographyPreview.swift"],
            "preview:no-sample-font-or-lineSpacing-animation")
    require("ReaderPreferences(fontSize: fontSize, lineSpacing: lineSpacing, theme: preferences.theme)" in preset_domain,
            "domain:preset-preserves-current-theme")

    # 5. ReaderDirectorySheet.swift & ReaderDirectoryFooter.swift stable loading slot contracts.
    sheet = sources["App/Reading/ReaderDirectorySheet.swift"]
    sheet_code = stripped["App/Reading/ReaderDirectorySheet.swift"]
    footer = sources["App/Reading/ReaderDirectoryFooter.swift"]
    footer_code = stripped["App/Reading/ReaderDirectoryFooter.swift"]

    require(".animation(" not in sheet_code, "directory-sheet:no-list-or-scrollTo-animation")
    require("if model.state.loading && (model.state.page?.chapters.isEmpty ?? true) {" in sheet,
            "directory-sheet:list-loading-row-gated-to-nil-or-empty-page-only")
    require(sheet_code.count("ProgressView(") == 1, "directory-sheet:single-initial-or-empty-ProgressView")
    require(
        "ReaderDirectoryFooter(rangeLabel: page.rangeLabel,\n"
        "                            loading: model.state.loading,\n"
        "                            previousDisabled: page.start == 0 || model.state.loading,\n"
        "                            nextDisabled: page.start + page.chapters.count >= page.total || model.state.loading,"
        in sheet,
        "directory-sheet:footer-receives-true-rangeLabel-and-loading-state",
    )

    require(".animation(" not in footer_code, "directory-footer:no-implicit-animation")
    require("ProgressView" not in footer_code and "@State" not in footer_code
            and "@ObservedObject" not in footer_code and "Task" not in footer_code,
            "directory-footer:stateless-no-background-spinner-or-task")
    require("let loading: Bool" in footer, "directory-footer:pure-loading-input")
    require("private static let loadingSlotWidth: CGFloat = 16" in footer,
            "directory-footer:constant-16pt-loading-slot-width")

    range_fn = footer[footer.index("private func rangeText(singleLine: Bool)"):]
    require('Image(systemName: "hourglass")' in range_fn
            and ".frame(width: Self.loadingSlotWidth)" in range_fn
            and ".opacity(loading ? 1 : 0)" in range_fn,
            "directory-footer:static-hourglass-in-fixed-width-slot")
    require("Color.clear" in range_fn
            and ".frame(width: Self.loadingSlotWidth, height: 1)" in range_fn,
            "directory-footer:symmetrical-balancing-slot-does-not-fix-text-height")
    require(range_fn.count(".accessibilityHidden(true)") == 2
            and ".accessibilityElement(children: .ignore)" in range_fn
            and '.accessibilityLabel("目录范围，\\(rangeLabel)")' in range_fn
            and '.accessibilityValue(loading ? "正在读取目录" : "")' in range_fn,
            "directory-footer:combined-ax-range-label-and-loading-value")
    require(footer.count("rangeText(singleLine:") == 8 and footer.count("ViewThatFits(in: .horizontal)") == 3,
            "directory-footer:all-seven-callsites-reuse-rangeText-across-three-ViewThatFits")

    # 6. Protected ReaderScreen, ReaderToolVisibility, and Shelf Navigation invariants.
    screen = sources["App/Reading/ReaderScreen.swift"]
    visibility = sources["App/Reading/ReaderToolVisibility.swift"]
    content = sources["App/ContentView.swift"]
    nav = sources["App/Library/LibraryPlannedNavigation.swift"]

    fill_bg = '.background(appearance.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))'
    header = screen[screen.index('private func titleBar('):screen.index('private var panelPresentation:')]
    require(fill_bg in header and '.stroke' not in header and '.overlay' not in header,
            'screen:titlebar-single-soft-surface-no-button-cover')
    require(".allowsHitTesting(visible && tools.canInteract).accessibilityHidden(!visible)" in screen,
            "screen:titleBar-hitTesting-and-ax-gate-intact")
    require("var request: UUID?\n        mutateTools { request = $0.beginExit() }" in screen,
            "screen:single-flight-exit-save-gate-intact")
    require(".transaction { transaction in transaction.animation = nil }" in visibility
            and ".animation(reduceMotion ? nil : ReaderMotion.toolVisibility," in visibility,
            "tool-visibility:child-transaction-isolation-and-reduceMotion-gate-intact")
    require(".animation(" not in stripped["App/ContentView.swift"]
            and ".navigationDestination(isPresented: plannedFeaturePresentation)" in content
            and "guard allowed, activeRoute == nil else { return false }" in nav
            and "guard activeRoute?.id == id else { return false }" in nav,
            "navigation:single-destination-and-no-shelf-list-animation")

    from check_ui_control_cohesion import f1_press_layers
    checks.extend(f1_press_layers(sources, callers=('preset',))['checks'])
    return checks


def verify_hash_map_against_baseline(baseline: dict, current_digests: dict[str, dict]) -> dict:
    """Compare 214 baseline paths against current digests; 4 whitelisted must change, 210 must match."""
    whitelist_mod = set(MOTION_WHITELIST_MODIFIED)
    baseline_files = baseline["files"]
    if len(baseline_files) != 214:
        raise AssertionError(f"Expected 214 baseline paths, got {len(baseline_files)}")

    unchanged_non_whitelist = []
    modified_whitelist = []
    unexpected_drift = []

    for rel, expected in baseline_files.items():
        actual = current_digests.get(rel)
        if actual is None:
            unexpected_drift.append({"path": rel, "reason": "missing"})
            continue
        if rel in whitelist_mod:
            if actual == expected:
                unexpected_drift.append({"path": rel, "reason": "whitelisted-file-unchanged"})
            else:
                modified_whitelist.append(rel)
        else:
            if actual == expected:
                unchanged_non_whitelist.append(rel)
            else:
                unexpected_drift.append({"path": rel, "reason": "protected-path-drifted", "expected": expected, "actual": actual})

    if unexpected_drift or len(modified_whitelist) != 4 or len(unchanged_non_whitelist) != 210:
        raise AssertionError(
            f"Baseline protection violation: modified_whitelist={len(modified_whitelist)}, "
            f"unchanged_non_whitelist={len(unchanged_non_whitelist)}, drift={unexpected_drift}"
        )

    group_counts = {}
    for group_name, paths in baseline["groups"].items():
        unchanged = sum(1 for p in paths if p not in whitelist_mod and current_digests[p] == baseline_files[p])
        whitelisted_in_group = sum(1 for p in paths if p in whitelist_mod)
        group_counts[group_name] = {
            "baseline_total": len(paths),
            "whitelisted_modified": whitelisted_in_group,
            "expected_unchanged": len(paths) - whitelisted_in_group,
            "actual_unchanged": unchanged,
        }
    return {
        "baseline_total": 214,
        "whitelisted_modified": len(modified_whitelist),
        "non_whitelisted_unchanged": len(unchanged_non_whitelist),
        "groups": group_counts,
    }


def verify_negative_controls(live_sources: dict[str, str], baseline: dict | None, live_digests: dict[str, dict] | None) -> list[str]:
    """Mutate in-memory copies ONLY (zero disk writes) and confirm the checker rejects every violation."""
    rejected_cases: list[str] = []

    def expect_source_rejection(label: str, rel: str, old: str, new: str) -> None:
        if old not in live_sources[rel]:
            raise AssertionError(f"Negative-control anchor missing in {rel} for {label}: {old!r}")
        mutated = dict(live_sources)
        mutated[rel] = mutated[rel].replace(old, new, 1)
        try:
            verify_source_contracts(mutated)
        except AssertionError:
            rejected_cases.append(label)
        else:
            raise AssertionError(f"Negative control unexpectedly PASSED: {label}")

    # Group 1: Broad animation scope / withAnimation around model commits.
    expect_source_rejection(
        "reject:settings-scrollview-broad-animation",
        "App/Reading/ReaderSettingsView.swift",
        '.accessibilityIdentifier("reader.settings.scroll")',
        '.accessibilityIdentifier("reader.settings.scroll").animation(ReaderMotion.selectionFeedback, value: draft)',
    )
    expect_source_rejection(
        "reject:settings-commitDraft-wrapped-in-withAnimation",
        "App/Reading/ReaderSettingsView.swift",
        "preferences = value\n        changed()",
        "withAnimation { preferences = value; changed() }",
    )
    expect_source_rejection(
        "reject:theme-outer-swatch-animated",
        "App/Reading/ReaderSettingsView.swift",
        'Text("阅").font(.system(size: 22))',
        'Text("阅").font(.system(size: 22)).animation(selectionAnimation, value: selectionMotionKey)',
    )

    # Group 2: Missing Reduce Motion gate or iOS 17+ animation APIs.
    expect_source_rejection(
        "reject:missing-reduceMotion-nil-gate",
        "App/Reading/ReaderSettingsView.swift",
        "let selectionAnimation = reduceMotion ? nil : ReaderMotion.selectionFeedback",
        "let selectionAnimation: Animation? = ReaderMotion.selectionFeedback",
    )
    expect_source_rejection(
        "reject:missing-reduceMotion-transaction-clear",
        "App/Reading/ReaderSettingsView.swift",
        "if reduceMotion { transaction.animation = nil }",
        "if false { transaction.animation = nil }",
    )
    expect_source_rejection(
        "reject:ios17-snappy-animation",
        "App/Reading/ReaderMotion.swift",
        ".easeOut(duration: selectionFeedbackDuration)",
        ".snappy(duration: selectionFeedbackDuration)",
    )
    expect_source_rejection(
        "reject:ios17-symbolEffect-in-settings",
        "App/Reading/ReaderSettingsView.swift",
        ".opacity(selected ? 1 : 0)",
        ".opacity(selected ? 1 : 0).symbolEffect(.bounce, value: selected)",
    )

    expect_source_rejection('reject:option-shape-mismatch', 'App/Reading/ReaderSettingsView.swift',
                            'contentShape(RoundedRectangle(cornerRadius: 16', 'contentShape(RoundedRectangle(cornerRadius: 8')
    expect_source_rejection('reject:permanent-option-outline', 'App/Reading/ReaderSettingsView.swift',
                            '.fill(selected ? appearance.surface : .clear)', '.stroke(appearance.accent)')
    expect_source_rejection('reject:option-fill-on-wrong-shape', 'App/Reading/ReaderSettingsView.swift',
                            'RoundedRectangle(cornerRadius: 16, style: .continuous)', 'Circle()')
    theme_start = live_sources['App/Reading/ReaderSettingsView.swift'].index('private func themeButton')
    altered = dict(live_sources)
    altered['App/Reading/ReaderSettingsView.swift'] = (live_sources['App/Reading/ReaderSettingsView.swift'][:theme_start] +
        live_sources['App/Reading/ReaderSettingsView.swift'][theme_start:].replace(
            'contentShape(RoundedRectangle(cornerRadius: 16', 'contentShape(RoundedRectangle(cornerRadius: 8', 1))
    try:
        verify_source_contracts(altered)
    except (AssertionError, ValueError):
        rejected_cases.append('reject:theme-only-whole-card-shape-mismatch')
    else:
        raise AssertionError('Accepted theme-only shape mismatch')

    # Group 3: Slider release-to-apply, preset theme isolation, or active guard regressions.
    expect_source_rejection(
        "reject:slider-commits-on-every-drag-step",
        "App/Reading/ReaderSettingAdjustment.swift",
        "if !dragging { commit() }",
        "commit()",
    )
    expect_source_rejection(
        "reject:preset-overwrites-reading-theme",
        "Sources/ReaderDomain/ReaderTypographyPreset.swift",
        "ReaderPreferences(fontSize: fontSize, lineSpacing: lineSpacing, theme: preferences.theme)",
        "ReaderPreferences(fontSize: fontSize, lineSpacing: lineSpacing, theme: .paper)",
    )
    expect_source_rejection(
        "reject:commitDraft-drops-isActive-guard",
        "App/Reading/ReaderSettingsView.swift",
        "private func commitDraft() {\n        guard isActive() else { return }",
        "private func commitDraft() {",
    )

    # Group 4: Directory duplicate loading row, missing Footer loading wire, missing constant slot, or predicted range.
    expect_source_rejection(
        "reject:directory-unconditional-list-loading-row",
        "App/Reading/ReaderDirectorySheet.swift",
        "if model.state.loading && (model.state.page?.chapters.isEmpty ?? true) {",
        "if model.state.loading {",
    )
    expect_source_rejection(
        "reject:directory-footer-missing-loading-wire",
        "App/Reading/ReaderDirectorySheet.swift",
        "loading: model.state.loading,",
        "loading: false,",
    )
    expect_source_rejection(
        "reject:directory-footer-removes-balancing-16pt-slot",
        "App/Reading/ReaderDirectoryFooter.swift",
        "Color.clear\n                .frame(width: Self.loadingSlotWidth, height: 1)",
        "EmptyView()",
    )
    expect_source_rejection(
        "reject:directory-footer-predicts-fake-next-range",
        "App/Reading/ReaderDirectorySheet.swift",
        "ReaderDirectoryFooter(rangeLabel: page.rangeLabel,",
        'ReaderDirectoryFooter(rangeLabel: "\\(page.start + 33)",',
    )
    expect_source_rejection(
        "reject:directory-footer-background-ProgressView-spinner",
        "App/Reading/ReaderDirectoryFooter.swift",
        'Image(systemName: "hourglass")',
        "ProgressView()",
    )

    expect_source_rejection('reject:titlebar-foreground-hit-cover', 'App/Reading/ReaderScreen.swift',
        '.background(appearance.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))',
        '.overlay(appearance.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))')

    if baseline is not None and live_digests is not None:
        for protected_path, label in (
            ("App/Reading/ReaderScreen.swift", "reject-hash:protected-ReaderScreen-drift"),
            ("App/Reading/ReaderViewport.swift", "reject-hash:protected-ReaderViewport-drift"),
            ("App/Reading/ReaderViewModel.swift", "reject-hash:protected-ReaderViewModel-drift"),
            ("App/Library/LibraryPlannedNavigation.swift", "reject-hash:protected-LibraryPlannedNavigation-drift"),
        ):
            tampered_digests = copy.deepcopy(live_digests)
            tampered_digests[protected_path] = {"sha256": "0" * 64, "bytes": 1}
            try:
                verify_hash_map_against_baseline(baseline, tampered_digests)
            except AssertionError:
                rejected_cases.append(label)
            else:
                raise AssertionError(f"Baseline hash negative control unexpectedly PASSED: {label}")

    return rejected_cases


def default_baseline_path() -> Path | None:
    scratch = os.environ.get("PI_SCRATCH_DIR")
    if not scratch:
        return None
    candidate = Path(scratch) / "motion-polish-diagnosis-20261030T1251575559117Z" / "baseline.json"
    return candidate if candidate.is_file() else None


def verify_git_and_protection(baseline_path: Path | None) -> dict:
    env = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
    head = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True, env=env).strip()
    status_lines = subprocess.check_output(
        ["git", "-C", str(ROOT), "status", "--porcelain=v1", "--untracked-files=all"],
        text=True,
        encoding="utf-8",
        env=env,
    ).splitlines()
    staged_bytes = len(
        subprocess.check_output(["git", "-C", str(ROOT), "diff", "--cached", "--no-ext-diff", "--binary"], env=env)
    )
    if staged_bytes != 0:
        raise AssertionError(f"Expected 0 staged diff bytes, got {staged_bytes}")

    result: dict = {
        "head": head,
        "staged_diff_bytes": staged_bytes,
        "status_count": len(status_lines),
        "baseline_checked": False,
    }

    if baseline_path is not None:
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
        if head != baseline["head"]:
            raise AssertionError(f"HEAD {head} != baseline {baseline['head']}")
        index_digest = digest_file(ROOT / ".git" / "index")
        if index_digest != baseline["index_file"]:
            raise AssertionError(f".git/index drifted from baseline: {index_digest}")
        live_digests = {}
        for rel in baseline["files"]:
            target = ROOT / rel
            if target.is_file():
                live_digests[rel] = digest_file(target)
        comparison = verify_hash_map_against_baseline(baseline, live_digests)

        # Verify git status equals baseline status + ReaderMotion.swift modified + 2 controlled new files (if docs already written).
        baseline_status = set(baseline["status"].splitlines())
        allowed_extra_status = {
            " M App/Reading/ReaderMotion.swift",
            "?? scripts/check_ui_motion_polish.py",
            "?? docs/UI_MOTION_POLISH_LOCAL.md",
        }
        actual_status = set(status_lines)
        if not baseline_status.issubset(actual_status) or not (actual_status - baseline_status).issubset(allowed_extra_status):
            raise AssertionError(f"Unexpected git status delta: {sorted(actual_status ^ baseline_status)}")

        result.update(
            baseline_checked=True,
            baseline_path=str(baseline_path),
            index_bytes_unchanged=True,
            **comparison,
        )
        return result, baseline, live_digests

    return result, None, None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--historical-baseline', '--baseline', dest='baseline', type=Path, default=None,
                        help='Explicit historical 214-path hash protection only; no historical freeze is loaded by current default')
    args = parser.parse_args()

    live_sources = load_live_sources()
    source_checks = verify_source_contracts(live_sources)
    if args.baseline is None:
        from check_ui_control_cohesion import current_exact
        current_exact(live_sources)
        source_checks.append('current-exact-paint-deltas-guard-task-viewport-preserved')
    protection_info, baseline, live_digests = verify_git_and_protection(args.baseline)
    negative_controls = verify_negative_controls(live_sources, baseline, live_digests)
    inv_report = inventory.validate_source(ROOT)
    if inv_report["selected"] != 138 or inv_report["all_declared"] != 139:
        raise AssertionError(f"Unexpected test declaration inventory: {inv_report}")
    ast.parse(Path(__file__).read_text(encoding="utf-8"))

    report = {
        'contract_version': 'soft-editorial-current-7d55-preedit',
        'historical_protection': 'explicit --historical-baseline/--baseline only; old freeze files unchanged',
        "kind": "OFFLINE_MOTION_SOURCE_CONTRACTS_AND_NEGATIVE_CONTROLS_NOT_NATIVE",
        "scope_notice": (
            "Lexical/structural source contracts, in-memory negative controls, and SHA256 baseline protection only. "
            "Not Swift compilation, UIKit/SwiftUI runtime animation verification, or FPS/latency measurement."
        ),
        "source_contract_checks_passed": len(source_checks),
        "in_memory_negative_controls_rejected": len(negative_controls),
        "declared_test_inventory": {
            "selected": inv_report["selected"],
            "all_declared": inv_report["all_declared"],
            "native_executions": 0,
        },
        "protection": protection_info,
        "native_compilations": 0,
        "native_executions": 0,
        "ui_touch_executions": 0,
        "pixel_render_executions": 0,
        "fps_measurements": 0,
        "source_contract_checks": source_checks,
        "in_memory_negative_controls": negative_controls,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))


def device_motion_contracts(s):
    d=s['App/Reading/ReaderFloatingToolsView.swift'];v=s['App/Reading/ReaderToolVisibility.swift'];m=s['App/Reading/ReaderMotion.swift']
    checks=[]
    def need(ok,name):
        assert ok,name
        checks.append(name)
    need('static let toolVisibilityDuration: Double = 0.16' in m and
         'static let hiddenTravel: CGFloat = 6' in m and
         'static let dockPresentationDuration: Double = 0.10' in m and
         'static var dockPresentation: Animation { .easeOut(duration: dockPresentationDuration) }' in m,
         'device-motion:unchanged-show-hide-duration-travel-no-lengthening-as-optimization')
    need('.transaction { transaction in transaction.animation = nil }' in v and
         '.opacity(visible ? 1 : 0)' in v and '.offset(y: reduceMotion || visible ? 0 : hiddenOffset)' in v and
         '.animation(reduceMotion ? nil : ReaderMotion.toolVisibility,' in v and
         'value: reduceMotion ? 0 : (visible ? 1 : 2)' in v and
         'if reduceMotion { transaction.animation = nil }' in v and
         v.index('transaction.animation = nil')<v.index('.opacity(')<v.index('.animation('),
         'device-motion:visibility-child-isolation-opacity-small-transform-only-RM-immediate')
    screen=s['App/Reading/ReaderScreen.swift']
    need('.animation(' not in screen and 'withAnimation' not in screen and
         'onAnchor: model.visibleChanged' in screen and
         '.padding(.horizontal, layout == .tabs ? 0 : 16).padding(.bottom, layout == .tabs ? 0 : 8)' in screen,
         'device-motion:body-viewport-header-layout-not-in-animation-scope')
    c=d[d.index('    private var edgeDock:'):d.index('    private var collapseButton:')]
    transition='.transition(reduceMotion ? .identity : .asymmetric(insertion: .opacity, removal: .identity))'
    need(c.count(transition)==2 and c.count('.transaction { $0.animation = nil }')==2 and
         c.count('.transaction { $0.animation = nil }\n                '+transition)==2,
         'device-C:new-branch-opacity-only-immediate-removal-no-frame-or-layout-morph')
    need('.allowsHitTesting(trayExpanded && visible && state.canInteract)' in c and
         '.accessibilityHidden(!trayExpanded || !visible)' in c and
         '.allowsHitTesting(!trayExpanded && visible && state.canInteract)' in c and
         '.accessibilityHidden(trayExpanded || !visible)' in c,
         'device-C:leaving-branch-immediately-noninteractive-AX-inert')
    need(c.count('.animation(')==1 and
         '.animation(reduceMotion ? nil : ReaderMotion.dockPresentation, value: reduceMotion ? 0 : (trayExpanded ? 1 : 2))' in c and
         '.transaction { if reduceMotion { $0.animation = nil } }' in c and
         c.index('.animation(')<c.index('.frame(maxWidth: .infinity, alignment: .trailing)'),
         'device-C:local-existing-state-value-animation-before-nonanimated-anchor')
    need(d.count('.animation(')==1 and '.animation(' not in d[:d.index('    private var edgeDock:')] and
         all(x not in d+v+m for x in ('withAnimation','Task {','.task','Timer','asyncAfter','completion:','matchedGeometry','scaleEffect','repeatForever','.spring(','.blur(','.drawingGroup(','.compositingGroup(')),
         'device-motion:no-global-animation-new-task-delay-lock-or-heavy-effect')
    need('trayExpanded = true\n                    restoreFocus(to:' in c and
         'trayExpanded = false\n            restoreFocus(to: "dock.expand")' in d and
         'rememberFocus(target)\n        focusedControl = target' in d and
         c.count('.accessibilityIdentifier("reader.tools.expand")')==1 and d.count('.accessibilityIdentifier("reader.tools.collapse")')==1,
         'device-C:state-focus-actions-immediate-unique-IDs-no-completion-lock')
    return checks


def device_motion_negatives(s, preedit=None):
    d='App/Reading/ReaderFloatingToolsView.swift';v='App/Reading/ReaderToolVisibility.swift';m='App/Reading/ReaderMotion.swift'
    if preedit is None:
        from check_ui_control_cohesion import DEVICE_EVIDENCE
        preedit={p:(DEVICE_EVIDENCE/'before'/p).read_text(encoding='utf8') for p in (d,m)}
    mutations=[('real-preedit-instant-C',d,None,preedit[d]),
               ('real-preedit-motion-no-presentation',m,None,preedit[m]),
               ('visibility-animates-child-layout',v,'.transaction { transaction in transaction.animation = nil }','.transaction { _ in }'),
               ('reduce-motion-still-animates',v,'reduceMotion ? nil : ReaderMotion.toolVisibility','ReaderMotion.toolVisibility'),
               ('C-reduce-motion-still-animates',d,'reduceMotion ? nil : ReaderMotion.dockPresentation','ReaderMotion.dockPresentation'),
               ('C-child-layout-animated',d,'.transaction { $0.animation = nil }','.transaction { _ in }'),
               ('C-old-leaving-branch-fades',d,'removal: .identity','removal: .opacity'),
               ('C-old-branch-interactive',d,'.allowsHitTesting(trayExpanded && visible && state.canInteract)','.allowsHitTesting(true)'),
               ('C-old-branch-AX-leak',d,'.accessibilityHidden(!trayExpanded || !visible)','.accessibilityHidden(false)'),
               ('C-delayed-state',d,'trayExpanded = true','Task { trayExpanded = true }'),
               ('new-root-layout-animation',d,'.foregroundStyle(appearance.foreground).tint(appearance.accent)','.foregroundStyle(appearance.foreground).tint(appearance.accent).animation(.linear, value: trayExpanded)'),
               ('body-viewport-animation','App/Reading/ReaderScreen.swift','.sheet(item: panelPresentation)', '.animation(.linear, value: tools.visible).sheet(item: panelPresentation)'),
               ('too-much-travel',m,'hiddenTravel: CGFloat = 6','hiddenTravel: CGFloat = 20')]
    rejected=[]
    for name,p,a,b in mutations:
        if a is not None: assert a in s[p],name
        alt=dict(s);alt[p]=s[p].replace(a,b,1) if a is not None else b
        try: device_motion_contracts(alt)
        except (AssertionError,ValueError) as error: rejected.append(dict(name=name,by=str(error)))
        else: raise AssertionError('Accepted device motion regression '+name)
    return rejected


def device_motion_main():
    from check_ui_control_cohesion import device_sources,device_exact,device_protection
    s=device_sources()
    print(json.dumps(dict(kind='DEVICE_DOCK_MOTION_SOURCE_NOT_NATIVE',checks=device_motion_contracts(s),
                         negative_controls=device_motion_negatives(s),exact=device_exact(s),protection=device_protection(),
                         native_compilations=0,native_executions=0,FPS_measurements=0),ensure_ascii=False,indent=2))


if __name__ == "__main__":
    if sys.argv[1:]==['--device-release-ci']:
        from check_ui_control_cohesion import dock_release_ci
        print(json.dumps(dock_release_ci('motion'),ensure_ascii=False,indent=2))
    elif sys.argv[1:]==['--device-feedback']: device_motion_main()
    else: main()
