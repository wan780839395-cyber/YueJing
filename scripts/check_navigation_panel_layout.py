"""Offline source-contract and synthetic specification checks for shelf planned navigation,
typography settings layout, and directory 4-digit/button enclosure polish.

IMPORTANT BOUNDARY:
- Windows offline check only; never launches Swift, Xcode, Simulator, or UIKit/CoreText.
- Synthetic specification cases verify pure state/digit invariants and are counted separately;
  they do NOT substitute for Swift compilation, XCTest UI touch tests, or pixel rendering.
"""
import ast
import json
from pathlib import Path
import re
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts"))

import task3_test_inventory as inventory  # noqa: E402

TOUCHED_SWIFT_FILES = (
    "App/ContentView.swift",
    "App/Library/LibraryPlannedEntriesView.swift",
    "App/Library/LibraryPlannedNavigation.swift",
    "App/Reading/ReaderCompactButtonStyle.swift",
    "App/Reading/ReaderDirectoryChapterRow.swift",
    "App/Reading/ReaderDirectoryFooter.swift",
    "App/Reading/ReaderDirectorySheet.swift",
    "App/Reading/ReaderSettingAdjustment.swift",
    "App/Reading/ReaderSettingsView.swift",
)


def strip_swift_comments_and_strings(text: str) -> str:
    """Strip Swift line/block comments and string literals for lexical brace/token checks."""
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
                raise AssertionError(f"{rel_path}: mismatched delimiter {ch!r} at stripped offset {idx}")
            stack.pop()
    if stack:
        raise AssertionError(f"{rel_path}: unclosed delimiter {stack[-1][0]!r}")


def verify_source_contracts() -> list[str]:
    checks: list[str] = []

    def require(condition: bool, name: str) -> None:
        if not condition:
            raise AssertionError("Contract failed: " + name)
        checks.append(name)

    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in TOUCHED_SWIFT_FILES}
    stripped = {rel: strip_swift_comments_and_strings(text) for rel, text in sources.items()}

    # 1. Lexical & deployment-target hygiene across all 9 touched Swift files.
    for rel, code in stripped.items():
        check_balanced_delimiters(rel, code)
        require("navigationDestination(item:" not in sources[rel], f"{rel}:no-ios17-navigationDestination-item")
        require("navigationDestination(for:" not in sources[rel], f"{rel}:no-mixed-navigationDestination-for")
        require("@Observable" not in sources[rel] and "import Observation" not in sources[rel], f"{rel}:no-Observation")
        require("import SwiftData" not in sources[rel] and "ViewInspector" not in sources[rel], f"{rel}:no-unauthorized-imports")
    checks.append("all-nine-swift-files-balanced-delimiters")

    # 2. Planned Navigation contracts.
    nav = sources["App/Library/LibraryPlannedNavigation.swift"]
    entries = sources["App/Library/LibraryPlannedEntriesView.swift"]
    content = sources["App/ContentView.swift"]
    feature_src = (ROOT / "App/Library/LibraryPlannedFeature.swift").read_text(encoding="utf-8")
    feature_view = (ROOT / "App/Library/LibraryPlannedFeatureView.swift").read_text(encoding="utf-8")

    require("import Foundation" in nav and "import SwiftUI" not in nav and "import ReaderDomain" not in nav,
            "nav:pure-foundation-app-value-type")
    require("struct LibraryPlannedNavigation: Equatable, Sendable" in nav, "nav:value-struct-equatable-sendable")
    require("guard allowed, activeRoute == nil else { return false }" in nav, "nav:idle-to-active-once-guard")
    require("guard activeRoute?.id == id else { return false }" in nav, "nav:id-gated-end-guard")
    for forbidden in ("Task", "sleep", "asyncAfter", "Timer", "debounce", "ObservableObject"):
        require(forbidden not in nav, f"nav:no-{forbidden}")

    require("NavigationLink" not in stripped["App/Library/LibraryPlannedEntriesView.swift"],
            "entries:zero-NavigationLink-in-row")
    require("LibraryPlannedFeatureView" not in stripped["App/Library/LibraryPlannedEntriesView.swift"],
            "entries:zero-inline-destination-construction")
    require("let onOpenFeature: (LibraryPlannedFeature) -> Void" in entries, "entries:explicit-action-callback")
    require(entries.count("onOpenFeature(feature)") == 2, "entries:module-and-info-buttons-forward-feature")
    require(entries.count(".buttonStyle(.plain)") == 2, "entries:plain-button-style-prevents-list-row-coalescing")
    require('.disabled(!canOpenFeatures)' in entries, "entries:disabled-gate-retained")
    require('if dynamicType.isAccessibilitySize' in entries, "entries:accessibility-vertical-branch-retained")
    require(entries.count('.accessibilityIdentifier("library.planned.entry.\\(feature.rawValue)")') == 2,
            "entries:accessibility-identifiers-retained")

    require("@State private var plannedNavigation = LibraryPlannedNavigation()" in content,
            "content:scene-state-planned-navigation")
    require(
        "model.service != nil && model.canPresentLibraryFeedback && !model.importing" in content
        and "&& model.encodingChoice?.id == nil && model.message == nil" in content
        and "&& readerRoutes.presentation?.id == nil" in content,
        "content:six-clause-canOpenPlannedFeatures-retained",
    )
    require("onOpenFeature: openPlannedFeature" in content, "content:entries-callback-wired")
    require(content.count(".navigationDestination(isPresented: plannedFeaturePresentation)") == 1,
            "content:single-controlled-navigationDestination")
    require(content.index(".toolbar {") < content.index(".navigationDestination(isPresented: plannedFeaturePresentation)")
            < content.index('.accessibilityIdentifier("library.screen")'),
            "content:destination-attached-to-root-shell-outside-lazy-rows")
    require("let expectedID = plannedNavigation.activeRoute?.id" in content
            and "guard !isPresented, let expectedID else { return }" in content
            and "plannedNavigation.end(id: expectedID)" in content,
            "content:id-captured-dismissal-binding-no-onDisappear-clear")
    management = (ROOT / "App/Library/LibraryExploreSettings.swift").read_text(encoding="utf-8")
    require('onInformation(.diagnostics)' in management
            and 'onInformation: openInformation' in content
            and '.navigationDestination(isPresented: informationPresentation)' in content
            and 'ReaderDiagnosticsView(importState: model.importDiagnostics, importSummary: model.processingSummary)' in content,
            "content:diagnostics-action-and-controlled-parent-destination-preserved")
    require(".fullScreenCover(item: readerPresentation)" in content, "content:reader-fullscreen-cover-preserved")
    require('case comics' in feature_src and 'case aiStory' in feature_src
            and '.accessibilityIdentifier("library.planned.\\(feature.rawValue)")' in feature_view,
            "planned-feature-models-and-placeholder-view-unchanged")

    # 3. Shared ReaderCompactButtonStyle contracts.
    style = sources["App/Reading/ReaderCompactButtonStyle.swift"]
    require("var surfaceInset: CGFloat = 6" in style and "var outlined: Bool = false" in style,
            "button-style:default-inset6-no-outline-preserves-icon-buttons")
    require(".inset(by: surfaceInset)" in style and "shape.strokeBorder(" in style,
            "button-style:opt-in-non-inset-strokeBorder-inside-background")
    require("ReaderMotion.pressFeedback" in style and "if !animatePress { transaction.animation = nil }" in style
            and ".opacity(isEnabled ? 1 : 0.4)" in style,
            "button-style:pressed-disabled-reduceMotion-retained")
    require("allowsHitTesting" not in style and "accessibilityHidden" not in style,
            "button-style:no-global-hitTesting-or-ax-override")

    # 4. Typography Settings & Adjustment contracts.
    adj = sources["App/Reading/ReaderSettingAdjustment.swift"]
    settings = sources["App/Reading/ReaderSettingsView.swift"]
    preset_domain = (ROOT / "Sources/ReaderDomain/ReaderTypographyPreset.swift").read_text(encoding="utf-8")

    require(adj.count(".buttonStyle(ReaderCompactButtonStyle(tint: accent))") == 2,
            "adjustment:plus-minus-keep-default-inset6-style")
    require("VStack(alignment: .leading, spacing: 8)" in adj, "adjustment:consistent-8pt-vertical-spacing")
    require(".frame(minWidth: 34, alignment: .center)" in adj and ".monospacedDigit()" in adj,
            "adjustment:centered-monospaced-value-slot")
    require("if !editing, isActive() { commit() }" in adj and "if !dragging { commit() }" in adj
            and "func step(_ delta: Double)" in adj,
            "adjustment:release-to-apply-and-immediate-step-retained")
    for ax_id in ('"reader.\\(key).slider"', '"reader.\\(key).decrease"', '"reader.\\(key).value"', '"reader.\\(key).increase"'):
        require(ax_id in adj, f"adjustment:ax-{ax_id}")

    require(".adaptive(" not in settings, "settings:no-adaptive-four-column-left-shift")
    require("threeOptionLayout(ReaderTheme.allCases)" in settings
            and "threeOptionLayout(ReaderTypographyPreset.allCases)" in settings,
            "settings:three-equal-centered-columns-for-themes-and-presets")
    require("ViewThatFits(in: .horizontal)" in settings and "if dynamicType.isAccessibilitySize" in settings,
            "settings:narrow-and-accessibility-vertical-fallback")
    preset_fn = settings[settings.index("private func presetButton"):settings.index("private var restoreTypographyButton")]
    require(".overlay(alignment: .topTrailing)" in preset_fn
            and 'Image(systemName: "checkmark.circle.fill")' in preset_fn
            and "HStack" not in preset_fn,
            "settings:preset-checkmark-overlay-does-not-shift-centered-title")
    require(preset_fn.index(".padding(.horizontal, 14)") < preset_fn.index(".padding(.vertical, 10)")
            < preset_fn.index(".frame(minWidth: 84, maxWidth: .infinity, minHeight: 56)")
            < preset_fn.index(".background {"),
            "settings:preset-padding-inside-enclosing-strokeBorder")
    restore_fn = settings[settings.index("private var restoreTypographyButton"):settings.index("private var moreSection")]
    require(".padding(.horizontal, 14)" in restore_fn
            and ".frame(maxWidth: .infinity, minHeight: ReaderVisualStyle.minimumControlHeight, alignment: .center)" in restore_fn
            and "ReaderCompactButtonStyle(tint: appearance.accent, surfaceInset: 0, outlined: true)" in restore_fn
            and '!isActive() || ReaderTypographyPreset.standard.matches(draft)' in restore_fn
            and '.accessibilityIdentifier("reader.typography.restore")' in restore_fn,
            "settings:restore-centered-outlined-and-gated")
    require("range: 14...36" in settings and "range: 0...20" in settings, "settings:font-14-36-spacing-0-20-retained")
    require('.confirmationDialog("恢复默认排版？", isPresented: $showRestore' in settings
            and 'Button("恢复字号与行距") { apply(.standard) }' in settings,
            "settings:confirmation-restore-theme-isolation-retained")
    require("case .compact: 17; case .standard: 20; case .relaxed: 24" in preset_domain
            and "case .compact: 5; case .standard: 7; case .relaxed: 10" in preset_domain,
            "domain:preset-values-17-5-20-7-24-10-unchanged")

    # 5. Directory Sheet header, ChapterRow ordinal column, and Footer button enclosures.
    sheet = sources["App/Reading/ReaderDirectorySheet.swift"]
    row = sources["App/Reading/ReaderDirectoryChapterRow.swift"]
    footer = sources["App/Reading/ReaderDirectoryFooter.swift"]

    require('ReaderPanelHeader(title: "目录", appearance: appearance)' in sheet, "directory-sheet:clean-panel-title")
    require("if let page = model.state.page, page.total > 0 {\n                directorySummaryHeader(page: page)\n            }" in sheet,
            "directory-sheet:dedicated-total-chapters-subheader")
    require('Text("共 \\(total) 章")' in sheet and ".monospacedDigit()" in sheet
            and "shape.strokeBorder(" in sheet and '.accessibilityIdentifier("reader.directory.total")' in sheet,
            "directory-sheet:outlined-monospaced-total-badge")
    require("HStack(alignment: .center, spacing: 12)" in sheet and "Spacer(minLength: 12)" in sheet
            and "ViewThatFits(in: .horizontal)" in sheet,
            "directory-sheet:total-count-separated-and-wraps-when-narrow-or-large")
    require("totalCount: page.total" in sheet, "directory-sheet:passes-totalCount-to-chapter-row")
    require('.accessibilityIdentifier("reader.chapter.\\(page.start + item.offset)")' in sheet
            and '.accessibilityValue(current ? "当前章节" : "")' in sheet
            and "guard active, model.ownerRevision == owner else { return }" in sheet,
            "directory-sheet:selection-ownership-and-ax-retained")

    require("minWidth: 32" not in row and "minWidth: 50" not in row,
            "chapter-row:no-hardcoded-pixel-width-guess")
    require("static let columnSpacing: CGFloat = 16" in row and "spacing: Self.columnSpacing" in row,
            "chapter-row:clear-16pt-ordinal-to-title-spacing")
    require("static func ordinalColumnDigits(ordinal: Int, totalCount: Int) -> Int" in row
            and 'String(repeating: "8", count: columnDigits)' in row
            and ".hidden()" in row and ".monospacedDigit()" in row,
            "chapter-row:hidden-real-Text-monospaced-measurement-placeholder")
    require("dynamicType.isAccessibilitySize || columnDigits > Self.horizontalColumnLimit" in row
            and ".layoutPriority(1)" in row,
            "chapter-row:stacked-fallback-for-gt6-digits-or-accessibility-preserves-title-width")

    require(footer.count("ReaderCompactButtonStyle(tint: appearance.accent, surfaceInset: 0, outlined: true)") == 2,
            "directory-footer:all-buttons-use-non-inset-outlined-enclosure")
    for fn_name in ("private func currentButton", "private func pagingButton"):
        segment = footer[footer.index(fn_name):]
        segment = segment[:segment.index("\n    }\n") + 6]
        require(segment.index(".padding(.horizontal,") < segment.index(".padding(.vertical, 8)")
                < segment.index("minHeight: ReaderVisualStyle.minimumControlHeight")
                < segment.index("ReaderCompactButtonStyle("),
                f"directory-footer:{fn_name.split()[-1]}-padded-before-44pt-frame-and-border")
    require('Label("回到当前章节", systemImage: "scope")' in footer
            and 'pagingButton("上一组"' in footer and 'pagingButton("下一组"' in footer,
            "directory-footer:button-titles-and-icons-retained")
    require(footer.count("ViewThatFits(in: .horizontal)") == 3,
            "directory-footer:progressive-horizontal-to-vertical-fallbacks")

    # 6. Frozen 138 native test inventory & toolchain settings untouched.
    inv_report = inventory.validate_source(ROOT)
    require(inv_report["selected"] == 138 and inv_report["all_declared"] == 139
            and inv_report["native_executions"] == 0,
            "inventory:138-selected-test-declarations-intact")
    project_yml = (ROOT / "project.yml").read_text(encoding="utf-8")
    for token in ('MARKETING_VERSION: "0.2.0"', 'CURRENT_PROJECT_VERSION: "2"',
                  'IPHONEOS_DEPLOYMENT_TARGET: "16.6"', 'SWIFT_VERSION: "6.0"', 'exactVersion: "7.0.0"'):
        require(token in project_yml, f"project.yml:{token}")

    ast.parse(Path(__file__).read_text(encoding="utf-8"))
    checks.append("checker-python-ast-valid")
    return checks


def verify_synthetic_specifications() -> list[str]:
    """Pure specification checks mirroring the value-state and digit/range formulas.
    Counted separately; never reported as Swift or UIKit execution.
    """
    cases: list[str] = []

    def require(condition: bool, label: str) -> None:
        if not condition:
            raise AssertionError("Synthetic spec failed: " + label)
        cases.append(label)

    # Confirm our formula parameters match the live Swift constants in ReaderDirectoryChapterRow.swift.
    row_src = (ROOT / "App/Reading/ReaderDirectoryChapterRow.swift").read_text(encoding="utf-8")
    limit_match = re.search(r"static let horizontalColumnLimit = (\d+)", row_src)
    spacing_match = re.search(r"static let columnSpacing: CGFloat = (\d+)", row_src)
    assert limit_match and int(limit_match.group(1)) == 6
    assert spacing_match and int(spacing_match.group(1)) == 16

    def ordinal_column_digits(ordinal: int, total_count: int) -> int:
        highest = max(1, max(ordinal, total_count))
        return max(2, len(str(highest)))

    # A. Directory 999 / 1000 / 9999 / 10000 / 7-digit ordinal column stability & boundary specs.
    require(
        all(ordinal_column_digits(ch, 999) == 3 for ch in (1, 9, 10, 99, 100, 999)),
        "spec:total-999-reserves-uniform-3-digits-across-1-to-999",
    )
    require(
        all(ordinal_column_digits(ch, 1000) == 4 for ch in (1, 9, 99, 999, 1000)),
        "spec:total-1000-reserves-uniform-4-digits-no-jump-between-999-and-1000",
    )
    require(
        all(ordinal_column_digits(ch, 9999) == 4 for ch in (1, 32, 999, 1000, 4096, 9999)),
        "spec:total-9999-reserves-uniform-4-digits-across-1-to-9999",
    )
    require(
        all(ordinal_column_digits(ch, 10000) == 5 for ch in (1, 999, 9999, 10000)),
        "spec:total-10000-reserves-uniform-5-digits-compact-serif-tier",
    )
    require(
        ordinal_column_digits(1, 1_000_000) == 7 and ordinal_column_digits(1, 1_000_000) > 6,
        "spec:total-gt-6-digits-switches-to-stacked-layout-preserving-title-width",
    )

    # B. Directory summary header & 32-chapter group boundary formatting for 999 / 1000 / 9999 / 10000.
    page_size = 32
    for total in (1, 32, 33, 999, 1000, 9999, 10000):
        last_start = ((total - 1) // page_size) * page_size
        last_count = total - last_start
        badge = f"共 {total} 章"
        range_label = f"{last_start + 1}–{last_start + last_count} / {total}"
        prev_disabled = last_start == 0
        next_disabled = (last_start + last_count) >= total
        require(
            str(total) in badge and range_label.endswith(f"/ {total}")
            and next_disabled is True and prev_disabled is (total <= page_size),
            f"spec:directory-last-page-total-{total}-badge-and-paging-bounds",
        )

    # C. Planned navigation single-active-destination state machine specification.
    features = ("comics", "aiStory", "epub", "cover")

    class PlannedNavSpec:
        def __init__(self) -> None:
            self.active: tuple[uuid.UUID, str] | None = None
            self.displayed: str = "comics"

        def begin(self, feature: str, allowed: bool = True) -> bool:
            if not allowed or self.active is not None:
                return False
            self.active = (uuid.uuid4(), feature)
            self.displayed = feature
            return True

        def end(self, expected_id: uuid.UUID) -> bool:
            if self.active is None or self.active[0] != expected_id:
                return False
            self.active = None
            return True

    state = PlannedNavSpec()
    require(not state.begin("comics", allowed=False) and state.active is None,
            "spec:nav-disallowed-begin-rejected-while-idle")

    for target in features:
        require(state.begin(target, allowed=True) and state.active is not None and state.active[1] == target,
                f"spec:nav-single-open-{target}")
        first_id = state.active[0]
        # Competing repeated taps on same and other entries while active must all be rejected.
        rejected = [not state.begin(other, allowed=True) for _ in range(25) for other in features]
        require(all(rejected) and state.active == (first_id, target) and state.displayed == target,
                f"spec:nav-100-competing-requests-rejected-while-{target}-active")
        # Stale ID cannot end active route; cancelled swipe-back (no end call) keeps active route.
        require(not state.end(uuid.uuid4()) and state.active == (first_id, target),
                f"spec:nav-stale-id-rejected-while-{target}-active")
        require(state.end(first_id) and state.active is None and state.displayed == target,
                f"spec:nav-matching-id-ends-{target}-preserving-outgoing-display")
        require(not state.end(first_id) and state.active is None,
                f"spec:nav-duplicate-end-idempotent-{target}")

    # Late callback from route A after route B has opened must never clear route B.
    assert state.begin("comics", allowed=True) and state.active is not None
    route_a = state.active[0]
    assert state.end(route_a)
    assert state.begin("aiStory", allowed=True) and state.active is not None
    route_b = state.active[0]
    require(not state.end(route_a) and state.active == (route_b, "aiStory"),
            "spec:nav-late-routeA-callback-cannot-clear-active-routeB")
    require(state.end(route_b) and state.active is None, "spec:nav-routeB-clean-exit")

    return cases


def main() -> None:
    source_checks = verify_source_contracts()
    synthetic_cases = verify_synthetic_specifications()
    report = {
        "kind": "OFFLINE_SOURCE_AND_SYNTHETIC_SPEC_NOT_NATIVE",
        "source_contract_checks_passed": len(source_checks),
        "synthetic_specification_cases_passed": len(synthetic_cases),
        "native_executions": 0,
        "ui_touch_executions": 0,
        "pixel_render_executions": 0,
        "source_contract_checks": source_checks,
        "synthetic_specification_cases": synthetic_cases,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
