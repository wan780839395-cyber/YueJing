"""A06/EPUB batch checks. Local checks are not Swift or device acceptance."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import ast
import contextlib
import io
import re
import sqlite3
import struct
import tempfile
import zipfile
import xml.etree.ElementTree as ET
import binascii
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
DEPENDENCIES = {
    "grdb.swift": {
        "url": "https://github.com/groue/GRDB.swift.git", "version": "7.0.0",
        "revision": "4de97e6903d29697caae1179cdef8479c64c2639",
        "manifest": "8140971be34f0cc80ef71e96a2b709ff98358a5c7412fe2e2a1687a4cb21867a",
    },
    "zipfoundation": {
        "url": "https://github.com/weichsel/ZIPFoundation.git", "version": "0.9.19",
        "revision": "02b6abe5f6eef7e3cbd5f247c5cc24e246efcfe0",
        "manifest": "2dd90c2f70b1f3d17a4d73bd32ac97e5fc002eecd5797586edaf170def789fff",
    },
}
ZIP_LICENSE_SHA256 = "5d9ecf59967651f9483b87ddd8d89b0cff66ad0f4c67d8658cb24a7610b70222"


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_pins(pins):
    require(isinstance(pins, list) and len(pins) == 2, "Exactly two approved dependencies required")
    result = {}
    for pin in pins:
        identity = pin.get("identity", "").lower()
        require(identity in DEPENDENCIES and identity not in result, "Unexpected/duplicate dependency")
        wanted = DEPENDENCIES[identity]
        require(pin.get("kind") == "remoteSourceControl" and pin.get("location") == wanted["url"], "Dependency kind/source differs")
        state = pin.get("state", {})
        require(state.get("version") == wanted["version"] and state.get("revision") == wanted["revision"]
                and state.get("branch") is None, "Dependency version/revision differs")
        result[identity] = pin
    require(set(result) == set(DEPENDENCIES), "Missing approved dependency")
    return result


def validate_checkouts(pins, root=ROOT):
    selected = validate_pins(pins)
    folder = root / "build/SourcePackages/checkouts"
    records = {}
    for identity, pin in selected.items():
        matches = [p for p in folder.iterdir() if p.name.lower() == identity and p.is_dir() and not p.is_symlink()]
        require(len(matches) == 1, "Missing/ambiguous dependency checkout: " + identity)
        checkout = matches[0]
        revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
        manifest = digest(checkout / "Package.swift")
        require(revision == DEPENDENCIES[identity]["revision"] and manifest == DEPENDENCIES[identity]["manifest"],
                "Checkout revision/manifest differs: " + identity)
        records[identity] = dict(package=pin, checkout_revision=revision, package_manifest_sha256=manifest)
    return records


def dependency_self_check():
    pins = [dict(identity=k, kind="remoteSourceControl", location=v["url"],
                 state=dict(version=v["version"], revision=v["revision"])) for k, v in DEPENDENCIES.items()]
    validate_pins(pins)
    negatives = [pins[:1], pins + [pins[0]], [pins[0], pins[0]]]
    for index in range(2):
        for key, value in (("version", "99.0.0"), ("revision", "0" * 40), ("branch", "main")):
            bad = copy.deepcopy(pins); bad[index]["state"][key] = value; negatives.append(bad)
        bad = copy.deepcopy(pins); bad[index]["location"] += "/fork"; negatives.append(bad)
        bad = copy.deepcopy(pins); bad[index]["identity"] = "alien"; negatives.append(bad)
    for bad in negatives:
        try:
            validate_pins(bad)
        except ValueError:
            continue
        raise ValueError("Dependency negative control accepted")
    require(digest(ROOT / "App/Resources/ZIPFoundation-LICENSE.txt") == ZIP_LICENSE_SHA256, "ZIPFoundation license differs")
    return dict(kind="LOCAL_DEPENDENCY_CONTRACT_NOT_NATIVE", positive=1, negative=len(negatives), native_executions=0)


def migration_check():
    text = (ROOT / "Sources/ReaderDomain/LibrarySchema.swift").read_text(encoding="utf-8")
    sql = re.search(r'registerMigration\("v6-epub"\).*?"""(.*?)"""', text, re.S).group(1)
    db = sqlite3.connect(":memory:")
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript("CREATE TABLE books(id TEXT PRIMARY KEY,title TEXT); INSERT INTO books VALUES('old','keep');")
    before = db.execute("PRAGMA table_info(books)").fetchall(), db.execute("SELECT * FROM books").fetchall()
    db.executescript(sql)
    require(before == (db.execute("PRAGMA table_info(books)").fetchall(), db.execute("SELECT * FROM books").fetchall()), "v6 changed legacy books")
    require(db.execute("SELECT format FROM bookFormats").fetchall() == [("txt",)], "v6 default format differs")
    negatives = ["INSERT INTO bookFormats VALUES('missing','epub')", "INSERT INTO bookFormats VALUES('old','alien')",
        "INSERT INTO epubProgress VALUES('old','v','raw-byte-v1',X'00','s',1)",
        "INSERT INTO epubProgress VALUES('old','v','epub-text-node-utf16-v1',X'00','s',0)"]
    for statement in negatives:
        try:
            db.execute(statement)
        except sqlite3.IntegrityError:
            continue
        raise ValueError("Invalid EPUB SQL admitted")
    db.close()
    return dict(legacy_table_preserved=True, negatives=len(negatives))


def sample_check():
    from make_epub_acceptance_samples import epub, png
    configurations = [{}, {"version": 2}, {"cover": "none"}, {"cover": "damaged"}, {"fixed": True}, {"traversal": True}]
    xmls = 0
    for options in configurations:
        data = epub(**options)
        require(data == epub(**options), "Sample is nondeterministic")
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            require(archive.testzip() is None, "Sample ZIP CRC failed")
            require(archive.infolist()[0].filename == "mimetype" and archive.infolist()[0].compress_type == 0, "Sample mimetype differs")
            for name in archive.namelist():
                if name.endswith((".xml", ".opf", ".xhtml", ".ncx")):
                    ET.fromstring(archive.read(name)); xmls += 1
            require(("../outside.txt" in archive.namelist()) == options.get("traversal", False), "Unsafe fixture differs")
    data = png(); offset = 8; chunks = 0
    require(data[:8] == b'\x89PNG\r\n\x1a\n', "PNG signature differs")
    while offset < len(data):
        size = struct.unpack('>I', data[offset:offset+4])[0]
        payload = data[offset+4:offset+8+size]
        actual = struct.unpack('>I', data[offset+8+size:offset+12+size])[0]
        require(binascii.crc32(payload) & 0xffffffff == actual, "PNG chunk CRC differs")
        offset += 12 + size; chunks += 1
    require(offset == len(data), "PNG length differs")
    return dict(synthetic_zips=len(configurations), xml_documents=xmls, png_chunks=chunks, native_parser_executed=False)


def ui_failure_check():
    import run_reading_ui_tests as runner
    checked = 0
    for target in runner.UI_CLASSES:
        for code, timeout, export_fails, expected in [(0, False, False, None), (65, False, False, "NATIVE_FAILURE"),
                (65, False, True, "NATIVE_FAILURE"), (-9, True, True, "NATIVE_TIMEOUT"),
                (0, False, True, "ATTACHMENT_EXPORT_ERROR")]:
            provenance = dict(target=target, source_commit="a"*40, run_id="synthetic", run_attempt="1")
            calls = []
            def stream(*args, **kwargs):
                calls.append("native"); return code, timeout
            def export(*args):
                calls.append("export")
                if export_fails:
                    raise ValueError("synthetic attachment failure")
            with tempfile.TemporaryDirectory(prefix="epub-gate-") as folder, \
                 patch.object(runner, "stream_native", stream), patch.object(runner, "export_ui_evidence", export), \
                 patch.object(runner, "_UIProcessTimeline", lambda *args: None), contextlib.redirect_stderr(io.StringIO()):
                try:
                    result = runner._run_ui_attempt([], Path(folder), provenance, 480)
                except ValueError as error:
                    require(expected is not None and str(error).startswith(expected + ":"), "Failure precedence changed: " + str(error))
                else:
                    require(expected is None and result == (0, False), "Synthetic failure accepted")
                receipt = json.loads((Path(folder)/(target+"-execution.json")).read_text())
                require(receipt["native_exit"] == code and receipt["timed_out"] == timeout, "Native receipt overwritten")
                require(calls == ["native", "export"], "Native/export repeated or skipped")
            checked += 1
    return dict(synthetic_cases=checked, native_processes_started=0)


def batch_check():
    import task3_test_inventory as inventory
    inventory.validate_source()
    require(inventory.TOTAL == 205 and sum(inventory.COUNTS.values()) == 205, "Batch count differs")
    python_files = ["check_epub_batch", "make_epub_acceptance_samples", "task3_test_inventory", "run_reading_ui_tests", "audit_native_case_events", "validate_task3"]
    for name in python_files:
        ast.parse((ROOT/"scripts"/(name+".py")).read_text(encoding="utf-8"))
    for folder in [ROOT/"Sources/ReaderDomain/EPUB", ROOT/"App/EPUB"]:
        for path in folder.glob("*.swift"):
            text = path.read_text(encoding="utf-8")
            require(not re.search(r'^(?:PUT |CUT |<<<<<<<|=======|>>>>>>>)', text, re.M), "Stray edit marker: " + path.name)
            require(not any(s in text for s in ["import Observation", "import SwiftData", "@Observable"]), "Unsupported deployment API")
    return dict(kind="LOCAL_BATCH_CHECK_NOT_NATIVE", dependency=dependency_self_check(), migration=migration_check(),
                samples=sample_check(), failure_precedence=ui_failure_check(), python_ast_files=len(python_files),
                selected=205, declared=206, native_executions=0, physical_acceptance="not performed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    print(json.dumps(batch_check(), indent=2))
