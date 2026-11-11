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
        return migrator
    }
}
