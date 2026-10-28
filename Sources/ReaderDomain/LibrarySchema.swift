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
        return migrator
    }
}
