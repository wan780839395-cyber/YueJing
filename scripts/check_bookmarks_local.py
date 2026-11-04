"""Offline bookmark contracts + extracted production SQL smoke; NOT Swift/GRDB/UI tests."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import task3_test_inventory as inventory

ROOT = Path(__file__).resolve().parents[1]
DOMAIN = "Sources/ReaderDomain/"
APP = "App/Reading/"
FILES = [DOMAIN + name + ".swift" for name in (
    "LibrarySchema", "LibraryStore", "OpenedReader", "ReadingBookmark", "ReadingBookmarkPage", "BookmarkRequest")]
FILES += [APP + name + ".swift" for name in (
    "ReaderViewModel", "ReaderViewController", "ReaderScreen", "ReaderPanelHost",
    "ReaderBookmarksViewModel", "ReaderBookmarksView", "ReaderContentsSheet")]


def require(value, message):
    if not value:
        raise ValueError(message)


def contracts(text):
    required = {
        DOMAIN + "LibrarySchema.swift": [
            'registerMigration("v4-bookmarks")', 'UNIQUE (bookID, versionID, unit, rawByteOffset)',
            'REFERENCES books(id) ON DELETE CASCADE', "CHECK (unit = 'raw-byte-v1')",
            'registerMigration("v5-bookmark-names")', '$0.add(column: "customName", .text)'],
        DOMAIN + "LibraryStore.swift": [
            '!closedSessions.contains(session.id)', 'book.activeSession == session.id',
            'book.versionID == session.versionID', 'request.check()',
            'ORDER BY createdAt DESC, id ASC LIMIT ? OFFSET ?',
            'DELETE FROM bookmarks WHERE id = ? AND bookID = ?',
            'if let existing = try Self.bookmark(db, at: anchor) { return existing }',
            'UPDATE bookmarks SET customName = ? WHERE id = ? AND bookID = ?'],
        DOMAIN + "OpenedReader.swift": [
            'anchor.rawByteOffset >= metadata.bomByteCount', 'anchor.rawByteOffset < metadata.byteCount',
            'source.utf16Offset(for:', 'source.composedStart(at:', 'start == utf16.value',
            'source.rawByteOffset(for:', 'raw.value == anchor.rawByteOffset',
            'current.hasSamePosition(as: value)', 'lineFraction: 0', 'public func renameBookmark('],
        DOMAIN + "ReadingBookmark.swift": ['public let customName: String?', 'name.count <= 80',
            '.generalCategory == .control', 'CharacterSet.newlines.contains($0)', 'func hasSamePosition(as'],
        DOMAIN + "ReadingBookmarkPage.swift": ['pageSize = 32'],
        DOMAIN + "BookmarkRequest.swift": ['NSLock()', 'Task.checkCancellation()', 'lock.lock()', 'lock.unlock()'],
        APP + "ReaderViewController.swift": ['func bookmarkAnchor()', '!restoring, !interacting', 'let visible = actualVisibleAnchor()'],
        APP + "ReaderViewModel.swift": ['func prepareBookmarkWindow(', 'func applyBookmarkWindow(',
            'preparedBookmarkWindow == rendered.id', 'bookmarkPositionIsCurrent(context)',
            'viewport.controller?.sceneBindingID == context.binding', 'navigationGate.expect(window: rendered.id, navigation: navigation)',
            'let panel = bookmarkContext', 'let context = BookmarkPanelContext(presentation: presentation, life: lifecycle,',
            'preparedBookmarkContext = context', 'let context = preparedBookmarkContext',
            'if anchor != value', 'func refreshBookmarkCapture('],
        APP + "ReaderBookmarksViewModel.swift": ['@MainActor', 'ObservableObject', 'cancelOperation()',
            'defer { finish(operation.id) }', 'operationID == id', 'reader === owner',
            'if activity == .adding { cancelOperation() }', 'func rename(', 'catch is ReaderViewModel.BookmarkJumpError'],
        APP + "ReaderBookmarksView.swift": ['.confirmationDialog(', 'role: .destructive',
            '.buttonStyle(.borderless)', 'reader.bookmarks.confirmDelete', 'reader.bookmarks.empty',
            'Text(bookmark.displayTitle)', 'reader.bookmarks.confirmRename', 'ReadingBookmark.validatedCustomName(editedName)'],
        APP + "ReaderContentsSheet.swift": ['showingBookmarks = false', 'ReaderDirectorySheet(', 'ReaderBookmarksView(',
            'model.refreshBookmarkCapture(presentationID)'],
        APP + "ReaderScreen.swift": ['model.beginBookmarkPanel(id)', 'model.endBookmarkPanel(old)', 'selectedBookmark: selectBookmark'],
    }
    checked = []
    for path, tokens in required.items():
        for token in tokens:
            require(token in text[path], path + ': missing ' + token)
        checked.append(path)
    for path, marker in [(DOMAIN + 'LibraryStore.swift', '// Bookmark transactions'),
                         (DOMAIN + 'OpenedReader.swift', 'extension OpenedReader {'),
                         (APP + 'ReaderViewModel.swift', 'extension ReaderViewModel {')]:
        appended = text[path].split(marker, 1)[1]
        require(not re.search(r'\b(?:saveProgress|savePreferences|finishReading)\s*\(', appended),
                path + ': bookmark operations write reader state')
    require('saveProgress(' not in text[APP + 'ReaderBookmarksViewModel.swift'], 'UI bookmark mutation writes progress')
    prepare = text[APP + 'ReaderViewModel.swift'].split('func prepareBookmarkWindow(', 1)[1].split('func applyBookmarkWindow(', 1)[0]
    require(prepare.index('let context = BookmarkPanelContext(') < prepare.index('bookmarkPositionIsCurrent(context)'),
            'jump still uses stale add context')
    require(prepare.count('bookmarkPositionIsCurrent(context)') == 3, 'jump lease missing await boundary checks')
    require(not re.search(r'\b(?:anchor|window) =', prepare), 'prepare mutates current position/window')
    same_position = text[DOMAIN + 'ReadingBookmark.swift'].split('func hasSamePosition(', 1)[1].split('public init(', 1)[0]
    require('customName' not in same_position and 'rawByteOffset == other.rawByteOffset' in same_position,
            'rename must not invalidate strict anchor identity')
    addition = text[DOMAIN + 'LibraryStore.swift'].split('func addBookmark(', 1)[1].split('func deleteBookmark(', 1)[0]
    require('customName: customName' in addition and 'ReadingBookmark.validatedCustomName(name)' in addition,
            'named creation must validate and insert the name')
    require(addition.count('queue.write') == 1 and addition.count('value.insert(db)') == 1 and
            'renameBookmark(' not in addition and 'UPDATE bookmarks' not in addition, 'creation is not one insert transaction')
    require('chapterTitle: title, name: name, request: request' in text[DOMAIN + 'OpenedReader.swift'], 'reader drops initial name')
    require('id: bookmarkID, name: name, request: operation.request' in text[APP + 'ReaderBookmarksViewModel.swift'], 'UI model drops initial name')
    view = text[APP + 'ReaderBookmarksView.swift']
    require('if active && model.canAdd { editName() }' in view and 'model.add()' not in view,
            'add button must edit before writing')
    for token in ['model.add(name: editedName)', 'reader.bookmarks.confirmAdd', 'presenting: nameEditor',
                  'editor.presentation == presentationID', 'bookmarkActions(bookmark, ordinal: ordinal)',
                  'HStack(spacing: 12)', 'VStack(alignment: .leading, spacing: 8)',
                  'Label("重命名", systemImage: "pencil")', 'Label("删除", systemImage: "trash")']:
        require(token in view, 'name editor/action layout missing: '+token)
    return checked


def sql_smoke(text):
    schema = text[DOMAIN + 'LibrarySchema.swift'].split('registerMigration("v4-bookmarks")', 1)[1]
    migration = re.search(r'"""(.*?)"""', schema, re.S).group(1)
    store = text[DOMAIN + 'LibraryStore.swift'].split('// Bookmark transactions', 1)[1]
    page = re.search(r'SELECT \* FROM bookmarks WHERE bookID = \? ORDER BY[^\n]+', store).group()
    count = re.search(r'SELECT COUNT\(\*\) FROM bookmarks WHERE bookID = \?', store).group()
    delete = re.search(r'DELETE FROM bookmarks WHERE id = \? AND bookID = \?', store).group()
    size = int(re.search(r'pageSize = (\d+)', text[DOMAIN + 'ReadingBookmarkPage.swift']).group(1))
    db = sqlite3.connect(':memory:', isolation_level=None)
    checks = []
    try:
        db.execute('PRAGMA foreign_keys = ON')
        # Minimal synthetic parent table, NOT a reimplementation of v1/v2/v3 GRDB migrations.
        db.executescript("CREATE TABLE books(id TEXT PRIMARY KEY); INSERT INTO books VALUES ('a'), ('b');")
        db.executescript('BEGIN;\n' + migration + '\nCOMMIT;')
        checks.append('extracted_v4_schema')
        insert = 'INSERT INTO bookmarks VALUES (?, ?, ?, ?, ?, ?, ?)'
        rows = [(f'{i:03}', 'a', 'v1', 'raw-byte-v1', i, i // 10, None) for i in range(65)]
        db.executemany(insert, rows)
        db.execute(insert, ('b-record', 'b', 'v1', 'raw-byte-v1', 0, 100, None))
        def rejects(row):
            try:
                db.execute(insert, row)
            except sqlite3.IntegrityError:
                return
            raise ValueError('SQL accepted invalid synthetic row')
        for row in [
            ('duplicate', 'a', 'v1', 'raw-byte-v1', 0, 999, None),
            ('negative', 'a', 'v1', 'raw-byte-v1', -1, 0, None),
            ('unit', 'a', 'v1', 'utf16', 77, 0, None),
            ('foreign', 'missing', 'v1', 'raw-byte-v1', 0, 0, None),
            ('000', 'a', 'v1', 'raw-byte-v1', 77, 0, None),
        ]:
            rejects(row)
        checks.append('unique_primary_key_unit_range_foreign_key')
        expected = sorted(rows, key=lambda r: (-r[5], r[0]))
        actual = [r for start in (0, 32, 64) for r in db.execute(page, ('a', size, start))]
        require(actual == expected and db.execute(count, ('a',)).fetchone()[0] == 65, 'SQL paging/order/isolation')
        checks.append('extracted_bounded_page_and_count')
        db.execute(delete, ('000', 'b'))
        require(db.execute(count, ('a',)).fetchone()[0] == 65, 'cross-book deletion')
        checks.append('extracted_delete_book_isolation')
        db.execute(delete, (expected[-1][0], 'a'))
        total = db.execute(count, ('a',)).fetchone()[0]
        # Arithmetic is a smoke model only; native test exercises the real Swift clamp.
        offset = min(64, 0 if total == 0 else (total - 1) // size * size)
        require(offset == 32 and len(db.execute(page, ('a', size, offset)).fetchall()) == 32, 'last-page clamp model')
        checks.append('last_page_clamp_model_not_swift')
        db.execute("CREATE TRIGGER fail_delete AFTER DELETE ON bookmarks BEGIN SELECT RAISE(ABORT, 'synthetic'); END")
        before = db.execute(page, ('a', 100, 0)).fetchall()
        db.execute('BEGIN')
        try:
            db.execute(delete, (expected[0][0], 'a'))
        except sqlite3.IntegrityError:
            db.execute('ROLLBACK')
        else:
            raise ValueError('injected deletion did not fail')
        require(db.execute(page, ('a', 100, 0)).fetchall() == before, 'failed deletion changed rows')
        checks.append('extracted_delete_rollback')
        # GRDB alter DSL is checked above; this SQL is its explicit smoke model, NOT native migration execution.
        db.execute('ALTER TABLE bookmarks ADD COLUMN customName TEXT')
        upgraded = db.execute(page, ('a', 100, 0)).fetchall()
        require([r[:-1] for r in upgraded] == before and all(r[-1] is None for r in upgraded), 'v5 model changed old rows')
        checks.append('v5_alter_model_preserves_old_rows_not_grdb')
        rename = re.search(r'UPDATE bookmarks SET customName = \? WHERE id = \? AND bookID = \?', store).group()
        original = db.execute('SELECT * FROM bookmarks WHERE id = ?', (expected[0][0],)).fetchone()
        db.execute(rename, ('新的名称 👩‍💻', original[0], 'a'))
        renamed = db.execute('SELECT * FROM bookmarks WHERE id = ?', (original[0],)).fetchone()
        require(renamed[:-1] == original[:-1] and renamed[-1] == '新的名称 👩‍💻', 'rename changed anchor/time')
        db.execute(rename, ('cross-book', original[0], 'b'))
        require(db.execute('SELECT * FROM bookmarks WHERE id = ?', (original[0],)).fetchone() == renamed, 'cross-book rename')
        db.execute(rename, (None, original[0], 'a'))
        require(db.execute('SELECT * FROM bookmarks WHERE id = ?', (original[0],)).fetchone() == original, 'reset name')
        checks.append('extracted_rename_only_name_reset_and_book_isolation')
        db.execute("CREATE TRIGGER fail_name AFTER UPDATE OF customName ON bookmarks BEGIN SELECT RAISE(ABORT, 'synthetic'); END")
        db.execute('BEGIN')
        try:
            db.execute(rename, ('must rollback', original[0], 'a'))
        except sqlite3.IntegrityError:
            db.execute('ROLLBACK')
        else:
            raise ValueError('injected rename did not fail')
        require(db.execute('SELECT * FROM bookmarks WHERE id = ?', (original[0],)).fetchone() == original, 'rename rollback')
        checks.append('extracted_rename_rollback')
        db.executemany('INSERT INTO bookmarks VALUES (?, ?, ?, ?, ?, ?, ?, ?)', [
            ('near1', 'a', 'v1', 'raw-byte-v1', 1000, 10, 'same chapter', None),
            ('near2', 'a', 'v1', 'raw-byte-v1', 1003, 10, 'same chapter', None)])
        require(db.execute("SELECT COUNT(*) FROM bookmarks WHERE chapterTitleSnapshot = 'same chapter'").fetchone()[0] == 2,
                'same chapter nearby positions')
        checks.append('same_chapter_three_byte_distance_sql')
        # Explicit INSERT smoke model for the Codable/GRDB insertion, not Swift execution.
        named_insert = 'INSERT INTO bookmarks VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
        row = ('named-create', 'a', 'v1', 'raw-byte-v1', 1010, 11, 'chapter', '创建时名称')
        db.execute(named_insert, row)  # fail_name UPDATE trigger remains active: no second update needed.
        require(db.execute('SELECT * FROM bookmarks WHERE id = ?', (row[0],)).fetchone() == row, 'initial name not persisted')
        checks.append('named_creation_single_insert_sql_model')
        before_named_failure = db.execute(page, ('a', 100, 0)).fetchall()
        db.execute("CREATE TRIGGER fail_named_insert AFTER INSERT ON bookmarks BEGIN SELECT RAISE(ABORT, 'synthetic'); END")
        db.execute('BEGIN')
        try:
            db.execute(named_insert, ('named-failure', 'a', 'v1', 'raw-byte-v1', 1011, 11, None, '一起回滚'))
        except sqlite3.IntegrityError:
            db.execute('ROLLBACK')
        else:
            raise ValueError('named insert unexpectedly succeeded')
        require(db.execute(page, ('a', 100, 0)).fetchall() == before_named_failure, 'named creation partially committed')
        checks.append('named_creation_rollback_sql_model')
        db.execute('DROP TABLE bookmarks')
        db.execute('CREATE INDEX bookmarks_book_created_id ON books(id)')
        db.execute('BEGIN')
        try:
            # Execute each extracted statement inside a transaction, as GRDB migration does.
            for statement in migration.split(';'):
                if statement.strip():
                    db.execute(statement)
        except sqlite3.OperationalError:
            db.execute('ROLLBACK')
        else:
            raise ValueError('injected migration conflict did not fail')
        require(db.execute("SELECT name FROM sqlite_master WHERE name='bookmarks'").fetchone() is None, 'migration rollback')
        checks.append('extracted_v4_rollback_on_index_conflict')
    finally:
        db.close()
    return {'kind': 'PYTHON_SQLITE_EXTRACTED_SQL_NOT_GRDB', 'checks': checks,
            'sql_sha256': hashlib.sha256((migration + page + count + delete).encode()).hexdigest()}


def negative_contracts(text):
    mutations = [
        (DOMAIN + 'LibraryStore.swift', 'book.activeSession == session.id', 'true'),
        (DOMAIN + 'OpenedReader.swift', 'start == utf16.value', 'true'),
        (DOMAIN + 'LibrarySchema.swift', 'UNIQUE (bookID, versionID, unit, rawByteOffset)', ''),
        (APP + 'ReaderViewModel.swift', 'preparedBookmarkWindow == rendered.id', 'true'),
        (APP + 'ReaderBookmarksView.swift', '.confirmationDialog(', '.alert('),
        (DOMAIN + 'LibraryStore.swift', 'UPDATE bookmarks SET customName = ? WHERE id = ? AND bookID = ?', 'UPDATE bookmarks SET customName = ? WHERE id = ?'),
        (APP + 'ReaderViewModel.swift', 'preparedBookmarkContext = context', ''),
        (APP + 'ReaderViewModel.swift', 'if anchor != value', 'if true'),
        (APP + 'ReaderBookmarksView.swift', 'reader.bookmarks.confirmRename', 'missingRename'),
        (DOMAIN + 'ReadingBookmark.swift', 'name.count <= 80', 'true'),
        (DOMAIN + 'LibraryStore.swift', 'customName: customName)', 'customName: nil)'),
        (DOMAIN + 'OpenedReader.swift', 'chapterTitle: title, name: name, request: request', 'chapterTitle: title, request: request'),
        (APP + 'ReaderBookmarksViewModel.swift', 'id: bookmarkID, name: name, request: operation.request', 'id: bookmarkID, request: operation.request'),
        (APP + 'ReaderBookmarksView.swift', 'if active && model.canAdd { editName() }', 'if active { model.add() }'),
        (APP + 'ReaderBookmarksView.swift', 'editor.presentation == presentationID', 'true'),
    ]
    for path, before, after in mutations:
        changed = dict(text); changed[path] = changed[path].replace(before, after)
        try:
            contracts(changed)
        except ValueError:
            continue
        raise ValueError('Contract negative accepted: ' + before)
    return len(mutations)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    text = {path: (args.root / path).read_text(encoding='utf-8') for path in FILES}
    checked = contracts(text)
    reviewed = inventory.validate_source(args.root)
    for path in (args.root / 'scripts').glob('*.py'):
        ast.parse(path.read_text(encoding='utf-8-sig'), filename=str(path))
    print(json.dumps({'kind': 'OFFLINE_NOT_NATIVE', 'source_contract_files': checked,
        'negative_contract_fixtures': negative_contracts(text), 'sql': sql_smoke(text),
        'selected_declarations': reviewed['selected'], 'all_declarations': reviewed['all_declared'],
        'native_executions': 0, 'swift_compilation': 'not_run',
        'limitations': 'Text contracts and Python SQLite do not prove Swift types, GRDB, concurrency, UIKit, or device behavior.'},
        indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
