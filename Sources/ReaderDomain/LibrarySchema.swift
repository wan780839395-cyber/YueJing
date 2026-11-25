import GRDB

enum LibrarySchema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-books") { db in
            try db.create(table: "books") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("encodingRaw", .text).notNull()
                t.column("versionID", .text).notNull()
                t.column("byteCount", .integer).notNull()
                t.column("utf16Count", .integer).notNull()
                t.column("addedAt", .double).notNull()
                t.column("lastReadAt", .double)
            }
        }
        migrator.registerMigration("v2-reading-state") { db in
            try db.alter(table: "books") { $0.add(column: "activeSession", .text) }
            try db.create(table: "progress") { t in
                t.primaryKey("bookID", .text).references("books", onDelete: .cascade)
                t.column("versionID", .text).notNull()
                t.column("unit", .text).notNull()
                t.column("rawByteOffset", .integer).notNull()
                t.column("lineFraction", .double).notNull()
                t.column("sessionID", .text).notNull()
                t.column("sequence", .integer).notNull()
            }
            try db.create(table: "preferences") { t in
                t.primaryKey("id", .integer)
                t.column("data", .blob).notNull()
            }
        }
        migrator.registerMigration("v3-derived-pointers") { db in
            try db.create(table: "derivedArtifacts") { t in
                t.primaryKey("bookID", .text).references("books", onDelete: .cascade)
                t.column("versionID", .text).notNull()
                t.column("generation", .text).notNull()
                t.column("manifestSHA256", .text).notNull()
                t.column("byteCount", .integer).notNull()
            }
        }
        migrator.registerMigration("v4-bookmarks") { db in
            try db.execute(sql: """
                CREATE TABLE bookmarks (
                    id TEXT NOT NULL PRIMARY KEY,
                    bookID TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
                    versionID TEXT NOT NULL,
                    unit TEXT NOT NULL CHECK (unit = 'raw-byte-v1'),
                    rawByteOffset INTEGER NOT NULL CHECK (rawByteOffset >= 0),
                    createdAt DOUBLE NOT NULL,
                    chapterTitleSnapshot TEXT,
                    UNIQUE (bookID, versionID, unit, rawByteOffset)
                );
                CREATE INDEX bookmarks_book_created_id ON bookmarks(bookID, createdAt DESC, id ASC);
                """)
        }
        migrator.registerMigration("v5-bookmark-names") { db in
            try db.alter(table: "bookmarks") { $0.add(column: "customName", .text) }
        }
        migrator.registerMigration("v6-epub") { db in
            try db.execute(sql: """
                CREATE TABLE bookFormats (
                    bookID TEXT NOT NULL PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
                    format TEXT NOT NULL DEFAULT 'txt' CHECK(format IN ('txt','epub'))
                );
                INSERT INTO bookFormats(bookID) SELECT id FROM books;
                CREATE TABLE epubPackages (
                    bookID TEXT NOT NULL PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
                    versionID TEXT NOT NULL,
                    metadata BLOB NOT NULL,
                    cover BLOB
                );
                CREATE TABLE epubProgress (
                    bookID TEXT NOT NULL PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
                    versionID TEXT NOT NULL,
                    unit TEXT NOT NULL CHECK(unit = 'epub-text-node-utf16-v1'),
                    anchor BLOB NOT NULL,
                    sessionID TEXT NOT NULL,
                    sequence INTEGER NOT NULL CHECK(sequence > 0)
                );
                """)
        }
        migrator.registerMigration("v7-epub-ready-versions") { db in
            try db.create(table: "epubReadyVersions") { t in
                t.primaryKey("bookID", .text).references("books", onDelete: .cascade)
                t.column("directory", .text).notNull().unique()
            }
        }
        migrator.registerMigration("v8-epub-bookmarks") { db in
            try db.execute(sql: """
                CREATE TABLE epubBookmarks (
                    id TEXT NOT NULL PRIMARY KEY,
                    bookID TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
                    versionID TEXT NOT NULL,
                    unit TEXT NOT NULL CHECK(unit = 'epub-text-node-utf16-v1'),
                    path TEXT NOT NULL,
                    node INTEGER NOT NULL CHECK(typeof(node) = 'integer' AND node >= 0),
                    utf16Offset INTEGER NOT NULL CHECK(typeof(utf16Offset) = 'integer' AND utf16Offset >= 0),
                    viewportOffset REAL CHECK(viewportOffset BETWEEN -16384 AND 16384),
                    title TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    UNIQUE(bookID, versionID, unit, path, node, utf16Offset)
                );
                CREATE INDEX epubBookmarks_scope_created_id
                    ON epubBookmarks(bookID, versionID, unit, createdAt DESC, id ASC);
                """)
        }
        // Not a child of books: these exact unlink obligations survive the catalog commit.
        migrator.registerMigration("v9-managed-file-removals") { db in
            try db.execute(sql: """
                CREATE TABLE managedRemovals (
                    kind TEXT NOT NULL, name TEXT NOT NULL, token TEXT NOT NULL, PRIMARY KEY(kind, name)
                ) WITHOUT ROWID
                """)
        }
        migrator.registerMigration("v10-story-sessions") { db in
            try db.execute(sql: """
                CREATE TABLE storySessions (
                    id TEXT NOT NULL PRIMARY KEY,
                    bookID TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
                    versionID TEXT NOT NULL, bookTitle TEXT NOT NULL,
                    roleKind TEXT NOT NULL CHECK(roleKind IN ('canon','original')),
                    roleName TEXT NOT NULL, premise TEXT NOT NULL, opening TEXT NOT NULL,
                    createdAt DOUBLE NOT NULL
                );
                CREATE INDEX storySessions_book ON storySessions(bookID);
                """)
        }
        migrator.registerMigration("v11-story-turns") { db in
            try db.execute(sql: """
                CREATE TABLE storyTurns (
                    id TEXT NOT NULL PRIMARY KEY,
                    sessionID TEXT NOT NULL REFERENCES storySessions(id) ON DELETE CASCADE,
                    sequence INTEGER NOT NULL CHECK(typeof(sequence) = 'integer' AND sequence BETWEEN 1 AND 64),
                    action TEXT NOT NULL CHECK(typeof(action) = 'text' AND trim(action, char(9,10,11,12,13,32)) <> ''),
                    narration TEXT NOT NULL CHECK(typeof(narration) = 'text' AND narration <> ''),
                    consequence TEXT NOT NULL CHECK(typeof(consequence) = 'text' AND consequence <> ''),
                    UNIQUE(sessionID, sequence)
                );
                """)
        }
        migrator.registerMigration("v12-story-preset-versions") { db in
            try db.execute(sql: """
                CREATE TABLE storyPresetVersions (
                    id TEXT NOT NULL PRIMARY KEY CHECK(length(id) = 64),
                    name TEXT NOT NULL,
                    canSelect INTEGER NOT NULL CHECK(canSelect IN (0,1)),
                    snapshot BLOB NOT NULL,
                    importedAt REAL NOT NULL
                );
                ALTER TABLE storySessions ADD COLUMN presetID TEXT REFERENCES storyPresetVersions(id);
                """)
        }
        migrator.registerMigration("v13-story-model-turns") { db in
            try db.execute(sql: """
                CREATE TABLE storyModelOrigins (
                    turnID TEXT NOT NULL PRIMARY KEY REFERENCES storyTurns(id) ON DELETE CASCADE,
                    modelName TEXT NOT NULL CHECK(length(modelName) BETWEEN 1 AND 256)
                );
                """)
        }
        return migrator
    }
}
