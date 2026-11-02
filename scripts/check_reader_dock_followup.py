"""C-only source/protection checks. Not a Swift compiler, UI test or FPS measurement."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CONTENT = "App/ContentView.swift"
LAYOUT = "App/Library/LibraryLayout.swift"
SHELL = "App/Library/LibraryNavigationShell.swift"
SHELF = "App/Library/LibraryShelfContent.swift"
SETTINGS = "App/Library/LibraryExploreSettings.swift"
SCREEN = "App/Reading/ReaderScreen.swift"
DOCK = "App/Reading/ReaderFloatingToolsView.swift"
SWIFT = (CONTENT, LAYOUT, SHELL, SHELF, SETTINGS, SCREEN, DOCK)
ALLOWED = (*SWIFT, "scripts/check_reader_dock_followup.py", "docs/READER_DOCK_FOLLOWUP.md")
EDGE = "    private var edgeDock: some View {"
FORBIDDEN = re.compile(
    r"\bLibraryLayout\b|\.(?:direct|tabs)\b|\bTabView\b|\bchooseLayout\b|"
    r"\blibraryLayoutRawValue\b|dev\.yuejing\.ui\.libraryLayout\.v1|"
    r'"library\.layout"|\bfloatingCapsule\b|\bedgeBar\b|\bverticalPair\b'
)


def require(ok, name):
    if not ok:
        raise ValueError(name)


def fingerprint(path):
    data = path.read_bytes()
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def read_source(path):
    return path.read_bytes().decode("utf-8")


def replace_once(text, before, after=""):
    require(text.count(before) == 1, "unique-preimage-replacement:" + repr(before[:90]))
    return text.replace(before, after, 1)


def region(text, start, end):
    require(text.count(start) == text.count(end) == 1, "unique-source-region:" + repr(start[:70]))
    a, b = text.index(start), text.index(end)
    require(a < b, "source-region-order")
    return text[a:b]


def cut(text, start, end):
    return replace_once(text, region(text, start, end))


def unindent(text):
    # Remove only four leading spaces per nonempty line; never normalize string contents.
    lines = text.splitlines(keepends=True)
    require(all(not line.strip() or line.startswith("    ") for line in lines), "unindent-boundary")
    return "".join(line[4:] if line.strip() else line for line in lines)


def expected_sources(old):
    """Explicit approved text transformations against the real nine-path preimage, not HEAD."""
    expected = {}
    text = old[CONTENT]
    replacements = (
        ("    @AppStorage(LibraryLayout.storageKey) private var libraryLayoutRawValue = LibraryLayout.defaultLayout.rawValue\n", ""),
        ("    private var layout: LibraryLayout { LibraryLayout.restored(from: libraryLayoutRawValue) }\n", ""),
        ("LibraryNavigationShell(layout: layout, section:", "LibraryNavigationShell(section:"),
        ("managementOptions(asMenu: false)", "managementOptions()"),
        ('.navigationTitle(layout == .direct ? "阅境" : selectedSection.title)', '.navigationTitle(selectedSection.title)'),
        ("if layout == .direct || selectedSection == .shelf {", "if selectedSection == .shelf {"),
        ("ReaderScreen(model: route.model, routeID: route.id, layout: layout)", "ReaderScreen(model: route.model, routeID: route.id)"),
        ("            layout: layout, appearance: appearance, canOpenFeatures: canChangeManagement,\n", "            appearance: appearance,\n"),
        ("onRetry: { Task { await model.start() } }, onOpenFeature: openPlannedFeature)", "onRetry: { Task { await model.start() } })"),
        ("private func managementOptions(asMenu: Bool)", "private func managementOptions()"),
        ("LibraryManagementOptions(asMenu: asMenu, appearance:", "LibraryManagementOptions(appearance:"),
        ("            layout: layout, canChange: canChangeManagement, onAppearance: chooseAppearance,\n", "            canChange: canChangeManagement, onAppearance: chooseAppearance,\n"),
        ("            onLayout: chooseLayout, onOpenFeature:", "            onOpenFeature:"),
        ("guard layout == .sidebar, canChangeManagement else", "guard canChangeManagement else"),
    )
    for before, after in replacements:
        text = replace_once(text, before, after)
    text = cut(text, "                if layout == .direct {\n", "                if selectedSection == .shelf {\n")
    text = cut(text, "    private func chooseLayout(_ option: LibraryLayout) {\n", "    private var sectionSelection: Binding<LibrarySection> {\n")
    expected[CONTENT] = text
    expected[LAYOUT] = "import Foundation\n\n" + old[LAYOUT][old[LAYOUT].index("enum LibrarySection:"):]

    text = replace_once(old[SHELL], "    let layout: LibraryLayout\n")
    wrapper = region(text, "            if layout == .sidebar {\n", "        }\n        .onChange(of: drawerPresented)")
    require(wrapper.endswith("            }\n"), "sidebar-toolbar-wrapper")
    content = wrapper[len("            if layout == .sidebar {\n"):-len("            }\n")]
    text = replace_once(text, wrapper, unindent(content))
    root = region(text, "    @ViewBuilder private var rootContent: some View {\n", "    private var drawerLayer: some View {\n")
    text = replace_once(text, root,
        "    @ViewBuilder private var rootContent: some View {\n"
        "        switch section {\n"
        "        case .shelf: shelf\n"
        "        case .explore: explore\n"
        "        case .settings: settings\n"
        "        }\n    }\n\n")
    expected[SHELL] = replace_once(text, "格式、外观与布局请进入设置", "格式与外观请进入设置")

    text = old[SHELF]
    for field in ("    let layout: LibraryLayout\n", "    let canOpenFeatures: Bool\n", "    let onOpenFeature: (LibraryPlannedFeature) -> Void\n"):
        text = replace_once(text, field)
    text = replace_once(text, "showsShelfTitle: layout == .direct", "showsShelfTitle: false")
    text = replace_once(text,
        "                            if layout == .direct { directBookRow(book) }\n"
        "                            else { LibraryBookRow(book: book, appearance: appearance) }\n",
        "                            LibraryBookRow(book: book, appearance: appearance)\n")
    text = cut(text, "            if layout == .direct {\n", "            if serviceUnavailable {\n")
    expected[SHELF] = cut(text, "\n\n    private func directBookRow(_ book: LibraryBook) -> some View {\n", "\n}")

    text = old[SETTINGS]
    text = replace_once(text, "/// Same guarded actions in A's system menu and B/C's settings, without another route owner.",
                        "/// Guarded settings actions without another route owner.")
    for field in ("    let asMenu: Bool\n", "    let layout: LibraryLayout\n", "    let onLayout: (LibraryLayout) -> Void\n"):
        text = replace_once(text, field)
    text = cut(text, "            Menu {\n                ForEach(LibraryLayout.allCases", "        } header: {\n")
    text = replace_once(text, 'Text("外观与入口")', 'Text("外观")')
    text = replace_once(text,
        '            if !asMenu {\n'
        '                Text("外观仅改变管理界面，不改变阅读背景。入口切换保留原有三种导航。")\n'
        '                    .font(.footnote).fixedSize(horizontal: false, vertical: true)\n'
        '            }\n',
        '            Text("外观仅改变管理界面，不改变阅读背景。")\n'
        '                .font(.footnote).fixedSize(horizontal: false, vertical: true)\n')
    formats = region(text, "            if asMenu {\n", "        }.listRowBackground(appearance.surface)\n        Section(\"本地信息\")")
    c_formats = region(formats, "                LibraryPlannedEntriesView(", "            }\n")
    text = replace_once(text, formats, unindent(c_formats))
    option = region(text, "    @ViewBuilder\n    private func optionLabel(", "\n@MainActor\nstruct LibraryLicenseView:")
    c_option = region(option, "            ViewThatFits(in: .horizontal) {\n", "        }\n    }\n}\n")
    header = option[:option.index("\n        if asMenu {\n") + 1]
    expected[SETTINGS] = replace_once(text, option, header + unindent(c_option) + "    }\n}\n")

    text = replace_once(old[SCREEN], "    let layout: LibraryLayout\n")
    text = replace_once(text, "layout: layout, ")
    expected[SCREEN] = replace_once(text,
        ".padding(.horizontal, layout == .tabs ? 0 : 16).padding(.bottom, layout == .tabs ? 0 : 8)",
        ".padding(.horizontal, 16).padding(.bottom, 8)")

    text = old[DOCK]
    prefix = replace_once(text[:text.index("    var body: some View {\n")], "    let layout: LibraryLayout\n")
    modifiers = region(text, "        .foregroundStyle(appearance.foreground).tint(appearance.accent)\n", "        .onChange(of: layout) { _ in\n")
    expected[DOCK] = prefix + "    var body: some View {\n        edgeDock\n" + modifiers + "    }\n\n" + text[text.index(EDGE):]
    return expected


def source_contracts(current, expected, app_sources):
    checks = []

    def need(ok, name):
        require(ok, name)
        checks.append(name)

    for path, text in app_sources.items():
        need(FORBIDDEN.search(text) is None, "no-alternate-layout-reference:" + path)
    for path in SWIFT:
        need(current[path] == expected[path], "only-approved-C-transformations:" + path)
    dock = current[DOCK]
    need(dock.count("@State") == 1 and "@State private var trayExpanded = false" in dock, "one-existing-dock-state")
    need("ZStack(alignment: .bottomTrailing) {" in dock, "stable-right-anchored-C-container")
    need(".opacity(trayExpanded ? 1 : 0)" in dock and ".opacity(trayExpanded ? 0 : 1)" in dock, "complementary-C-visibility")
    need(".allowsHitTesting(trayExpanded && visible && state.canInteract)" in dock
         and ".allowsHitTesting(!trayExpanded && visible && state.canInteract)" in dock, "both-C-hit-gates")
    need(".accessibilityHidden(!trayExpanded || !visible)" in dock
         and ".accessibilityHidden(trayExpanded || !visible)" in dock, "both-C-accessibility-gates")
    need(".transaction { $0.animation = nil }" in dock and ".animation(" not in dock and ".transition(" not in dock,
         "no-secondary-dock-animation")
    need(not any(token in dock for token in ("Task {", "Timer", "asyncAfter", ".onChange", ".gesture(", ".safeAreaInset(", ".zIndex(")),
         "no-new-hooks-retries-or-geometry-workarounds")
    need('.fullScreenCover(item: readerPresentation)' in current[CONTENT] and '.id(route.id)' in current[CONTENT], "single-reader-route-identity-retained")
    return checks


def self_check(current, expected, app_sources, previous):
    mutations = (
        ("alternate-enum", LAYOUT, "import Foundation", "import Foundation\nenum LibraryLayout {}"),
        ("alternate-tab-navigation", SHELL, "        switch section {", "        TabView {\n        switch section {"),
        ("layout-picker-restored", SETTINGS, 'Text("外观")', 'Text("外观").accessibilityIdentifier("library.layout")'),
        ("old-defaults-restored", CONTENT, "    @State private var selectedSection", '    @AppStorage("dev.yuejing.ui.libraryLayout.v1") var oldLayout = "b"\n    @State private var selectedSection'),
        ("expanded-hit-leak", DOCK, ".allowsHitTesting(trayExpanded && visible && state.canInteract)", ".allowsHitTesting(true)"),
        ("expanded-AX-leak", DOCK, ".accessibilityHidden(!trayExpanded || !visible)", ".accessibilityHidden(false)"),
        ("collapsed-hit-leak", DOCK, ".allowsHitTesting(!trayExpanded && visible && state.canInteract)", ".allowsHitTesting(true)"),
        ("collapsed-AX-leak", DOCK, ".accessibilityHidden(trayExpanded || !visible)", ".accessibilityHidden(false)"),
        ("focus-target-changed", DOCK, 'restoreFocus(to: "dock.expand")', 'restoreFocus(to: "back")'),
        ("branch-remount", DOCK, "ZStack(alignment: .bottomTrailing) {", "ZStack(alignment: .bottomTrailing) { if trayExpanded {"),
        ("secondary-animation", DOCK, ".transaction { $0.animation = nil }", ".animation(.default, value: trayExpanded)"),
        ("reader-padding-drift", SCREEN, ".padding(.horizontal, 16).padding(.bottom, 8)", ".padding(.horizontal, 0).padding(.bottom, 0)"),
        ("reader-interaction-state-drift", SCREEN, "@State private var tools = ReadingToolsPresentation()", "@State private var tools = ReadingToolsPresentation(visible: true)"),
        ("reader-route-identity-drift", CONTENT, ".id(route.id)", ".id(UUID())"),
        ("import-busy-gate-removed", CONTENT, ".disabled(!model.canBeginFileSelection || !canChangeManagement)", ".disabled(false)"),
        ("drawer-navigation-gate-removed", CONTENT, "guard drawerPresented, canNavigateManagement else { return }", "guard drawerPresented else { return }"),
        ("book-order-identity-drift", SHELF, "ForEach(books) { book in", "ForEach(books.reversed()) { book in"),
        ("appearance-setting-write-drift", CONTENT, "appAppearanceRawValue = option.rawValue", 'appAppearanceRawValue = "changed"'),
    )
    rejected = []
    for name, path, before, after in mutations:
        require(before in current[path], "negative-anchor-missing:" + name)
        changed = dict(current)
        changed[path] = changed[path].replace(before, after, 1)
        app = dict(app_sources)
        app[path] = changed[path]
        try:
            source_contracts(changed, expected, app)
        except ValueError:
            rejected.append(name)
        else:
            raise ValueError("negative-accepted:" + name)
    try:
        source_contracts(previous, expected, previous)
    except ValueError:
        rejected.append("real-preimage-still-has-A-B-and-selector")
    else:
        raise ValueError("real-preimage-accepted")
    return {"kind": "IN_MEMORY_SOURCE_NEGATIVES_NOT_NATIVE", "count": len(rejected), "rejected": rejected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    baseline_path = args.baseline.resolve()
    require(baseline_path.is_relative_to((ROOT / "artifacts").resolve()), "baseline-must-be-project-evidence")
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    require(baseline["root"] == str(ROOT) and baseline["allowed"] == list(ALLOWED), "exact-nine-path-baseline")
    protected = baseline["protected"]
    for path in ALLOWED:
        preimage = baseline_path.parent / "preimage" / path
        require(fingerprint(preimage) == protected[str(ROOT / path)], "real-frozen-preimage:" + path)
    previous = {path: read_source(baseline_path.parent / "preimage" / path) for path in SWIFT}
    current = {path: read_source(ROOT / path) for path in SWIFT}
    expected = expected_sources(previous)
    app = {path.relative_to(ROOT).as_posix(): read_source(path) for path in (ROOT / "App").rglob("*.swift")}
    checks = source_contracts(current, expected, app)
    allowed_abs = {str(ROOT / path) for path in ALLOWED}
    immutable = {name: value for name, value in protected.items() if name not in allowed_abs}
    drift = [name for name, value in immutable.items() if not Path(name).is_file()
             or Path(name).is_symlink() or fingerprint(Path(name)) != value]
    require(not drift, "outside-nine-protected-file-drift:" + repr(drift))
    require(fingerprint(ROOT / ".git/index") == baseline["index_before"], "independent-index-changed")
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", PYTHONDONTWRITEBYTECODE="1")

    def git(*command):
        return subprocess.check_output(["git", "-C", str(ROOT), "-c", "core.quotepath=false", *command], cwd=ROOT, env=env)

    require(git("rev-parse", "HEAD").decode().strip() == baseline["head"], "HEAD-changed")
    require(not git("diff", "--cached", "--name-only"), "staged-changes")
    require(set(git("diff", "--name-only", "--no-renames").decode().splitlines()) == set(SWIFT), "unexpected-tracked-change")
    untracked = set(git("ls-files", "--others", "--exclude-standard", "-z").decode("utf-8").rstrip("\0").split("\0"))
    known = {Path(name).relative_to(ROOT).as_posix() for name in protected
             if Path(name).is_relative_to(ROOT)}
    require(not untracked - known, "unexpected-new-untracked-paths:" + repr(sorted(untracked - known)))
    git("diff", "--check")
    report = {
        "kind": "STATIC_SOURCE_AND_HASH_NOT_SWIFT_RUNTIME", "status": "passed",
        "source_contracts": checks, "source_contract_count": len(checks), "app_swift_files_scanned": len(app),
        "protected_total": len(protected), "protected_checked_outside_nine": len(immutable), "protection_drift": [],
        "index": fingerprint(ROOT / ".git/index"), "head": baseline["head"],
        "candidate": {path: fingerprint(ROOT / path) for path in ALLOWED},
        "native_executions": 0, "swift_compilations": 0, "fps_measured": False,
        "limits": "A/B removed, not performance-repaired. C node lifetime simplification is unmeasured; hidden content still lays out. No Swift/UIKit, hit-through, VO, frame timing or device acceptance proof."
    }
    if args.self_check:
        report["negative_controls"] = self_check(current, expected, app, previous)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print("C-only dock checks stopped: " + str(error), file=sys.stderr)
        sys.exit(1)
