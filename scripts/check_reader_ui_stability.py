"""Offline source contracts only. No Swift compilation, UI rendering or native execution."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import os

ROOT = Path(__file__).resolve().parents[1]
BASE = "fd9d9aa163cf9546bfe3b6f47e3bc8a82371d91a"
EXISTING = ["App/Reading/ReaderFloatingToolsView.swift", "App/Reading/ReaderScreen.swift",
            "App/Library/LibraryShelfContent.swift", "App/Reading/ReaderViewController.swift",
            "Tests/YueJingHostTests/ReaderThemeUpdateTests.swift", "Tests/YueJingUITests/ReadingFlowUITests.swift"]
NEW = ["App/Library/LibraryNoticeBanner.swift", "scripts/check_reader_ui_stability.py", "docs/READER_UI_STABILITY.md"]
DOCK, SCREEN, SHELF, VC, HOST, UI = EXISTING
BANNER = NEW[0]


def require(value, message):
    if not value:
        raise ValueError(message)


def git(*args):
    result = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, timeout=90,
                            env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    require(result.returncode == 0, "Read-only git failed: " + result.stderr.decode("utf-8", "replace"))
    return result.stdout


def block(text, start, end):
    require(text.count(start) == text.count(end) == 1, "Unique region anchors: " + start)
    return text[text.index(start):text.index(end) + len(end)]


def replace_once(text, before, after):
    require(text.count(before) == 1, "Unique approved change: " + before[:90])
    return text.replace(before, after, 1)


def contracts(files, base):
    checks = []
    def check(name, value):
        require(value, name)
        checks.append(name)
    dock, screen, shelf, vc, host, ui, banner = [files[n] for n in (*EXISTING, BANNER)]
    check("dock-opacity-only-no-offset-or-scale", ".transition(.opacity)" in dock and ".offset(" not in dock and ".scaleEffect(" not in dock)
    check("dock-shared-compact-surface", "dockSurface(cornerRadius: 24) { expandButton }" in dock)
    check("dock-shared-expanded-surfaces", dock.count("dockSurface(cornerRadius: 24)") == 3)
    check("dock-content-sized-and-accessible-fallback", "ViewThatFits(in: .horizontal)" in dock and "ScrollView(.vertical)" in dock and '.accessibilityIdentifier("reader.tools.scroll")' in dock)
    restored = replace_once(dock, "edgeDock\n                    .transition(.opacity)", "edgeDock\n                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: ReaderMotion.hiddenTravel)))")
    restored = replace_once(restored, "dockSurface(cornerRadius: 24) { expandButton }", "expandButton")
    expand = block(base[DOCK], "    private var expandButton:", "    private var collapseButton:")
    background = block(expand, "        .background {", "        .accessibilityIdentifier(\"reader.tools.expand\")")
    restored = replace_once(restored, '        .accessibilityIdentifier("reader.tools.expand")', background)
    check("dock-only-reviewed-geometry-paint-change", restored == base[DOCK])
    old = block(base[SCREEN], "                VStack(spacing: 0) {\n                    Spacer(minLength: 0)\n                    ReaderFloatingToolsView", "            .foregroundStyle(appearance.foreground).tint(appearance.accent)")
    new = block(screen, "            }\n            // Secondary layout:", "            .foregroundStyle(appearance.foreground).tint(appearance.accent)")
    check("dock-overlay-has-stable-bottom-trailing-anchor", '.overlay(alignment: .bottomTrailing)' in new and '.padding(.horizontal, 16).padding(.bottom, 8)' in new)
    check("screen-everything-else-byte-identical", replace_once(screen, new, old) == base[SCREEN])
    check("no-reader-insets-identity-or-gesture-workaround", all(t not in new for t in ("safeAreaInset", ".id(", "zIndex", "onTapGesture", "offset(", "GeometryReader")))
    old = block(base[SHELF], "            if let notice {", "            if importing {")
    new = block(shelf, "            if let notice {", "            if importing {")
    check("shelf-notice-is-one-compact-row", "Section {" not in new and "LibraryNoticeBanner(notice: notice, appearance: appearance, dismiss: onDismissNotice)" in new)
    check("shelf-notice-small-row-insets", "EdgeInsets(top: 2" in new and "bottom: 2" in new)
    check("shelf-import-progress-books-retry-unchanged", replace_once(shelf, new, old) == base[SHELF])
    check("banner-keeps-entire-authoritative-message", "Text(notice.title)" in banner and "Text(notice.detail)" in banner and ".fixedSize(horizontal: false, vertical: true)" in banner and all(x not in banner for x in ("lineLimit", "truncationMode", "minimumScaleFactor")))
    check("banner-compact-horizontal-close-control", "HStack(alignment: .top, spacing: 8)" in banner and "VStack(alignment: .leading, spacing: 2)" in banner and 'Label("关闭这条提示", systemImage: "xmark")' in banner and ".frame(width: 44, height: 44)" in banner)
    check("banner-explicit-dismiss-no-timer-or-business-work", "Button(action: dismiss)" in banner and all(x not in banner for x in ("Task", "onAppear", "async", "LibraryService", "Timer", "DispatchQueue", "@State", "onTapGesture")))
    check("banner-accessibility-separate-close", '.accessibilityIdentifier("library.notice.dismiss")' in banner and ".accessibilityElement(children: .contain)" in banner)
    policy = block(vc, "    static func interactionDiagnosticsOverlayEnabled", "    private func sampleInteractionDiagnostics()")
    check("diagnostics-release-always-off", '#if DEBUG\n        return environment["YUEJING_READER_DIAGNOSTICS"] == "1"\n        #else\n        return false\n        #endif' in policy)
    check("diagnostics-no-eager-label-allocation", "private var interactionDiagnosticLabel: UILabel?" in vc and "private let interactionDiagnosticLabel = UILabel()" not in vc)
    install = block(vc, "        // Never install the on-canvas", "        // END READER DIAGNOSTICS install")
    check("diagnostic-label-installed-only-behind-opt-in", install.count("let label = UILabel()") == 1 and 'if Self.interactionDiagnosticsOverlayEnabled(environment: ProcessInfo.processInfo.environment) {' in install and "interactionDiagnostics.install(label)\n        }" in install)
    check("diagnostic-passive-label-only", all(t in install for t in ("label.isUserInteractionEnabled = false", "label.isAccessibilityElement = false", "label.accessibilityElementsHidden = true")))
    check("diagnostics-layout-only-when-present", "if let interactionDiagnosticLabel {" in vc)
    restored = vc
    for name in ("storage", "install", "label frame"):
        start, end = "    // BEGIN READER DIAGNOSTICS " + name, "    // END READER DIAGNOSTICS " + name
        # The install/frame markers have 8-space indentation, contained by this suffix match.
        a, b = block(restored, start, end), block(base[VC], start, end)
        restored = replace_once(restored, a, b)
    check("native-touch-scroll-theme-scene-recorder-unchanged", restored == base[VC])
    check("host-tests-explicit-debug-opt-in-and-default-no-label", all(t in host for t in ('environment: [:]', '"YUEJING_READER_DIAGNOSTICS": "0"', '"YUEJING_READER_DIAGNOSTICS": "1"', '!controller.view.subviews.contains { $0.accessibilityIdentifier == "reader.diagnostics.overlay" }')))
    # Original statements remain in their original order; only new assertion lines may be added.
    old_lines = base[HOST].splitlines(); iterator = iter(host.splitlines())
    check("all-original-host-lines-preserved", all(any(x == line for x in iterator) for line in old_lines))
    def assertions(text):
        found = Counter()
        for match in re.finditer(r"\bXCT(?:Assert\w*|Fail)\s*\(", text):
            depth, quoted, escaped = 1, False, False
            for i in range(match.end(), len(text)):
                char = text[i]
                if quoted:
                    if escaped:
                        escaped = False
                    elif char == "\\":
                        escaped = True
                    elif char == '"':
                        quoted = False
                elif char == '"':
                    quoted = True
                elif char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        found[text[match.start():i + 1]] += 1
                        break
            else:
                raise ValueError("Unterminated assertion")
        return found
    old_asserts, new_asserts = assertions(base[UI]), assertions(ui)
    check("all97-original-ui-assertions-preserved", sum(old_asserts.values()) == 97 and not (old_asserts - new_asserts))
    check("ui-new-right-bottom-height-assertions", all(f"XCTAssertEqual(compactControlFrame.{key}, expandedControlFrame.{key}, accuracy: 0.5)" in ui for key in ("maxX", "maxY", "height")))
    check("ui-reexpanded-control-frame-assertion", "assertSameFrame(collapse.frame, expandedControlFrame)" in ui)
    # Strict App-return and actual exit/showTools helper tail must not change.
    marker = "    @MainActor func testOtherAppRoundTripRestoresCentralTapAndWindowUpdates()"
    check("strict-return-and-exit-query-helpers-unchanged", ui[ui.index(marker):] == base[UI][base[UI].index(marker):])
    return checks


def self_check(files, base):
    mutants = [(DOCK, "dockSurface(cornerRadius: 24) { expandButton }", "expandButton"),
               (DOCK, ".transition(.opacity)", ".transition(.offset(y: 6))"),
               (DOCK, "ScrollView(.vertical)", "VStack"),
               (SCREEN, ".overlay(alignment: .bottomTrailing)", ".overlay(alignment: .bottomLeading)"),
               (SCREEN, ".padding(.bottom, 8)", ".padding(.bottom, 16)"),
               (BANNER, "Text(notice.detail)", 'Text("完成")'),
               (BANNER, ".frame(width: 44, height: 44)", ".frame(width: 24, height: 24)"),
               (BANNER, "Button(action: dismiss)", "Button(action: {})"),
               (VC, "#else\n        return false", "#else\n        return true"),
               (VC, '#if DEBUG\n        return environment["YUEJING_READER_DIAGNOSTICS"] == "1"', '#if DEBUG\n        return true'),
               (VC, "private var interactionDiagnosticLabel: UILabel?", "private let interactionDiagnosticLabel = UILabel()"),
               (VC, "label.isUserInteractionEnabled = false", "label.isUserInteractionEnabled = true"),
               (UI, "XCTAssertEqual(compactControlFrame.height, expandedControlFrame.height, accuracy: 0.5)", "// assertion removed"),
               (UI, "assertSameFrame(collapse.frame, expandedControlFrame)", "// frame check removed")]
    rejected = []
    for path, before, after in mutants:
        require(before in files[path], "Negative-control target absent")
        changed = dict(files); changed[path] = files[path].replace(before, after, 1)
        try:
            contracts(changed, base)
        except ValueError:
            rejected.append(path + ": " + before[:75])
        else:
            raise ValueError("Unsafe mutation accepted: " + before)
    # Arithmetic from the unchanged source metrics + shared 4pt surface padding, not SwiftUI rendering.
    require(".padding(4)" in files[DOCK], "Shared surface padding differs")
    geometry = []
    for control in (44, 48, 53, 64, 88):
        collapsed, expanded = control + 2 * 4, control + 2 * 4
        require(collapsed == expanded, "Shared surface arithmetic differs")
        geometry.append(dict(control_minimum=control,collapsed_outer_minimum=collapsed,expanded_horizontal_outer_minimum=expanded))
    return dict(negative_controls_rejected=rejected,shared_padding_arithmetic=geometry,
                limitation="Static source contracts and arithmetic only, not Swift layout/AX/device execution.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    base = {n: git("show", BASE + ":" + n).decode("utf-8") for n in EXISTING}
    files = {n: (ROOT / n).read_text(encoding="utf-8") for n in (*EXISTING, BANNER)}
    checks = contracts(files, base)
    import task3_test_inventory as inventory
    inv = inventory.validate_source()
    expected_paths = [n for n in git("ls-tree", "-r", "--name-only", BASE).decode().splitlines()]
    require(len(expected_paths) == 196, "Baseline tracked count differs")
    for n in expected_paths:
        if n not in EXISTING:
            require((ROOT / n).read_bytes() == git("show", BASE + ":" + n), "Unrelated tracked source changed: " + n)
    require(all((ROOT / n).is_file() for n in NEW), "Required new files absent")
    changed = set(git("diff", "--name-only", BASE).decode().splitlines())
    require(changed <= set(EXISTING + NEW), "Unapproved tracked delta")
    result = dict(kind="OFFLINE_SOURCE_CONTRACTS_NOT_NATIVE", base=BASE, contracts=checks,
                  unrelated_baseline_paths_unchanged=190,selected=inv["selected"],declared=inv["all_declared"],native_executions=0)
    if args.self_check:
        result["self_check"] = self_check(files, base)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
