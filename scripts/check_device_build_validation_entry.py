"""Exercise the device workflow's real runpy loader; offline, never native tests."""
import ast
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ios-build.yml"
STEP = "      - name: Validate device dependencies and package an IPA with TESTS NOT RUN manifest\n"
START = "          python3 - <<'PY'\n"
END = "          PY\n"
# Compare AST only; execute source extracted from the workflow, not this template.
EXPECTED = '''import json, os, re, runpy, sys
from pathlib import Path
sys.path.insert(0, str(Path("scripts").resolve()))
g = runpy.run_path("scripts/validate_task3.py")
'''


def check(condition, label, checks):
    if not condition:
        raise AssertionError(label)
    checks.append(label)


def loader_source(text):
    """Fail closed if the unique package heredoc or its four-node loader drifts."""
    if text.count(STEP) != 1:
        raise ValueError("Missing/ambiguous device package step")
    step = text.split(STEP)[1].split("\n      - name:", 1)[0]
    if START not in step or END not in step:
        raise ValueError("Missing device package Python heredoc")
    body = step.split(START, 1)[1].split(END, 1)[0]
    if any(line and not line.startswith("          ") for line in body.splitlines()):
        raise ValueError("Unexpected heredoc indentation")
    source = "\n".join(line[10:] for line in body.splitlines())
    tree = ast.parse(source)
    prefix = ast.Module(body=tree.body[:4], type_ignores=[])
    calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
             and isinstance(node.func, ast.Attribute) and node.func.attr == "run_path"]
    if len(calls) != 1 or ast.dump(prefix) != ast.dump(ast.parse(EXPECTED)):
        raise ValueError("Device loader drift: review imports, absolute scripts path and runpy target")
    return "\n".join(ast.get_source_segment(source, node) for node in prefix.body) + "\n"


class ExternalCommandForbidden(RuntimeError):
    pass


def child(mode):
    checks, attempts = [], []
    check(sys.flags.isolated == 1 and sys.dont_write_bytecode, "isolated_no_bytecode", checks)
    check(Path.cwd().resolve() == ROOT and "task3_test_inventory" not in sys.modules
          and all(Path(p).resolve() != ROOT / "scripts" for p in sys.path), "clean_root_import_context", checks)
    source = json.load(sys.stdin)["loader"]

    def deny(*args, **kwargs):
        attempts.append("blocked")
        raise ExternalCommandForbidden("offline_not_native: external commands forbidden")

    def audit(event, args):
        if event.startswith(("subprocess.", "os.exec", "os.spawn", "os.posix_spawn")) or event in (
                "os.system", "os.startfile", "pty.spawn"):
            deny()

    sys.addaudithook(audit)
    for name in ("Popen", "run", "call", "check_call", "check_output", "getoutput", "getstatusoutput"):
        setattr(subprocess, name, deny)
    for name in ("system", "popen", "startfile"):
        if hasattr(os, name):
            setattr(os, name, deny)
    namespace = {}
    try:
        exec(compile(source, str(WORKFLOW) + ":loader", "exec"), namespace)
    except ModuleNotFoundError as error:
        if mode != "without_path":
            raise
        check(error.name == "task3_test_inventory", "exact_missing_sibling_module", checks)
    else:
        check(mode != "without_path", "loader_succeeded", checks)
        g = namespace["g"]
        check(g["__name__"] == "<run_path>" and Path(g["__file__"]).resolve() == ROOT / "scripts/validate_task3.py",
              "real_validator_not_main", checks)
        # This revision has no validate_native_dependencies symbol: the device
        # dependency checks are inline in YAML. Verify its actual imported helpers.
        names = ("require", "run", "digest", "unsigned", "grdb_checkout")
        check(all(callable(g.get(name)) and Path(g[name].__code__.co_filename).resolve()
                  == ROOT / "scripts/validate_task3.py" for name in names), "real_validation_callables", checks)
        inventory = g["inventory"]
        check(inventory is sys.modules["task3_test_inventory"]
              and Path(inventory.__file__).resolve() == ROOT / "scripts/task3_test_inventory.py",
              "inventory_resolves_from_repository", checks)
        report = inventory.validate_source(ROOT)  # declarations only; no test execution
        check(inventory.TOTAL == report["selected"] == 138 and report["all_declared"] == 139
              and report["native_executions"] == 0, "reviewed_138_selected_declarations", checks)
        if mode == "blocked_commands":
            for label, operation in (("subprocess", lambda: subprocess.run(["offline-command-must-not-launch"])),
                                     ("os_system", lambda: os.system("offline-command-must-not-launch"))):
                try:
                    operation()
                except ExternalCommandForbidden:
                    checks.append(label + "_forbidden")
                else:
                    raise AssertionError(label + " escaped external-command guard")
    check(len(attempts) == (2 if mode == "blocked_commands" else 0), "no_unexpected_command_attempts", checks)
    print(json.dumps(dict(case=mode, checks=checks, blocked_attempts=len(attempts), native_executions=0)))


def main():
    text = WORKFLOW.read_text(encoding="utf-8")
    checks = []
    loader = loader_source(text)
    checks.append("actual_workflow_loader_ast_bound")
    mutations = {
        "missing_step": text.replace(STEP, ""),
        "duplicate_step": text + STEP,
        "missing_loader": text.replace('g = runpy.run_path("scripts/validate_task3.py")', "g = {}"),
        "path_setup_drift": text.replace('sys.path.insert(0, str(Path("scripts").resolve()))', 'sys.path.append("scripts")'),
        "main_guard_bypass": text.replace('runpy.run_path("scripts/validate_task3.py")',
                                         'runpy.run_path("scripts/validate_task3.py", run_name="__main__")'),
    }
    for label, changed in mutations.items():
        try:
            loader_source(changed)
        except (ValueError, SyntaxError):
            checks.append("reject_" + label)
        else:
            raise AssertionError("Accepted workflow loader mutation: " + label)
    # Remove only the actual path-setup AST node for the causal negative control.
    nodes = ast.parse(loader).body
    without_path = "\n".join(ast.get_source_segment(loader, node) for i, node in enumerate(nodes) if i != 2)
    results = []
    for mode, source in (("positive", loader), ("without_path", without_path), ("blocked_commands", loader)):
        result = subprocess.run([sys.executable, "-I", "-B", str(Path(__file__).resolve()), "--child", mode],
                                cwd=ROOT, input=json.dumps(dict(loader=source)), text=True,
                                capture_output=True, timeout=30, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        if result.returncode:
            raise AssertionError(mode + " child failed:\n" + result.stdout + result.stderr)
        value = json.loads(result.stdout)
        check(value["case"] == mode and value["native_executions"] == 0 and not result.stderr,
              mode + "_child_result", checks)
        results.append(value)
    print(json.dumps(dict(kind="offline_not_native", passed=len(checks) + sum(len(r["checks"]) for r in results),
                          checks=checks, cases=results, native_executions=0, external_commands_executed=0), indent=2))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--child" and sys.argv[2] in (
            "positive", "without_path", "blocked_commands"):
        child(sys.argv[2])
    elif len(sys.argv) == 1:
        main()
    else:
        raise SystemExit("No arguments supported (child modes are internal)")
