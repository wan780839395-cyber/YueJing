import Foundation
import GRDB
import Testing
@testable import ReaderDomain

struct EPUBAuthorStyleMigrationTests {
    @Test func legacyPackageWithoutAuthorStyleRevisionDecodesCompatibly() throws {
        let f = try EPUBLibraryFixture()
        defer { f.remove() }

        let png = try EPUBLibraryFixture.image(width: 16, height: 16)
        let fullPackage = EPUBPackage(
            sourceSHA256: String(repeating: "a", count: 64),
            parserVersion: EPUBFormat.parserVersion,
            title: "Legacy Compatibility Book",
            spine: ["OPS/ch1.xhtml", "OPS/ch2.xhtml"],
            navigation: [
                EPUBNavigationItem(title: "Chapter 1", path: "OPS/ch1.xhtml", fragment: "h1", depth: 0),
                EPUBNavigationItem(title: "Chapter 2", path: "OPS/ch2.xhtml", fragment: nil, depth: 0)
            ],
            resources: [
                EPUBResource(path: "OPS/ch1.xhtml", mediaType: "application/xhtml+xml", sha256: String(repeating: "1", count: 64), byteCount: 120),
                EPUBResource(path: "OPS/ch2.xhtml", mediaType: "application/xhtml+xml", sha256: String(repeating: "2", count: 64), byteCount: 140),
                EPUBResource(path: "OPS/cover.png", mediaType: "image/png", sha256: EPUBResourceStore.digest(png), byteCount: png.count)
            ],
            textNodes: [
                "OPS/ch1.xhtml": ["Chapter 1", "A😀e\u{301} text"],
                "OPS/ch2.xhtml": ["Chapter 2", "Second body"]
            ],
            coverPath: "OPS/cover.png",
            ready: nil,
            authorStyleRevision: EPUBFormat.authorStyleRevision
        )

        let readyDir = f.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: readyDir, withIntermediateDirectories: false)
        let compactPackage = try EPUBReadyArtifact.writeNodes(package: fullPackage, folder: readyDir)

        for original in [fullPackage, compactPackage] {
            let encoded = try JSONEncoder().encode(original)
            let strippedData = try jsonStrippingAuthorStyleRevision(encoded, setExplicitNull: false)
            let nullData = try jsonStrippingAuthorStyleRevision(encoded, setExplicitNull: true)

            for legacyData in [strippedData, nullData] {
                let decoded = try JSONDecoder().decode(EPUBPackage.self, from: legacyData)
                #expect(decoded.authorStyleRevision == nil)
                #expect(decoded != original)
                #expect(decoded.sourceSHA256 == original.sourceSHA256)
                #expect(decoded.parserVersion == original.parserVersion)
                #expect(decoded.versionID == original.versionID)
                #expect(decoded.title == original.title)
                #expect(decoded.spine == original.spine)
                #expect(decoded.navigation == original.navigation)
                #expect(decoded.resources == original.resources)
                #expect(decoded.textNodes == original.textNodes)
                #expect(decoded.coverPath == original.coverPath)
                #expect(decoded.ready == original.ready)

                let snapshot = try EPUBMetadataSnapshot(
                    metadata: legacyData,
                    readyRoot: original.ready == nil ? nil : f.root
                )
                #expect(snapshot.package.authorStyleRevision == nil)
                if original.ready != nil {
                    #expect(try snapshot.package.nodes(at: "OPS/ch1.xhtml") == fullPackage.textNodes["OPS/ch1.xhtml"])
                }
            }
        }
    }

    @Test func authorStyleMigrationRebuildsReadyAndNonReadyLegacyPackagesPreservingTextProgressAndSource() async throws {
        // Case A: Legacy DB package WITH existing Ready v1 (ready != nil, missing authorStyleRevision).
        do {
            let f = try EPUBLibraryFixture()
            defer { f.remove() }

            let archive = try writeStyledFontEPUB(at: f.root.appendingPathComponent("legacy-ready.epub"))
            let originalArchiveBytes = try Data(contentsOf: archive)
            let receipt = try await f.install(archive)
            let bookID = receipt.book.id

            let installed = try await f.store.storedEPUBSnapshot(bookID: bookID)
            let oldReadyDir = try #require(installed.package.ready?.directory)
            let oldReadyFolder = await f.store.epubReadyURL().appendingPathComponent(oldReadyDir, isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: oldReadyFolder.path))

            // Simulate pre-author-style DB JSON: remove authorStyleRevision, remove font resource, and use old unstyled XHTML digest.
            try await rewriteMetadataAsPreAuthorStyleLegacy(in: f.managed, bookID: bookID)
            let legacySnapshot = try await f.store.storedEPUBSnapshot(bookID: bookID)
            #expect(legacySnapshot.package.ready?.directory == oldReadyDir)
            #expect(legacySnapshot.package.authorStyleRevision == nil)
            #expect(legacySnapshot.package.resource(at: "OPS/Fonts/book.ttf") == nil)

            // Save reading position and preferences under the legacy package before migration.
            let targetPath = "OPS/Text/ch2.xhtml"
            let expectedCh1Nodes = try #require(try legacySnapshot.package.nodes(at: "OPS/Text/ch1.xhtml"))
            let expectedCh2Nodes = try #require(try legacySnapshot.package.nodes(at: targetPath))
            let savedPosition = EPUBReadingPosition(
                bookID: bookID,
                versionID: legacySnapshot.package.versionID,
                path: targetPath,
                node: 1,
                utf16Offset: 2,
                viewportOffset: 36
            )
            let savedPrefs = ReaderPreferences(fontSize: 24, lineSpacing: 10, theme: .dark)
            try await persistReadingProgress(
                store: f.store,
                snapshot: legacySnapshot,
                position: savedPosition,
                preferences: savedPrefs
            )

            // Open on a fresh LibraryService: must upgrade from original archive and replace old Ready artifact.
            let freshService = LibraryService(store: try LibraryStore(root: f.managed))
            let opened = try await freshService.openEPUB(id: bookID)
            #expect(opened.openingTimings.readyPreparationOccurred)
            #expect(opened.openingTimings.chapterIndexedMetadata)
            #expect(!opened.reusedResources)
            #expect(opened.publication.package.authorStyleRevision == EPUBFormat.authorStyleRevision)
            let newReadyDir = try #require(opened.publication.package.ready?.directory)
            #expect(newReadyDir != oldReadyDir)
            #expect(try await f.store.referencedEPUBReadyDirectories() == [newReadyDir])
            #expect(!FileManager.default.fileExists(atPath: oldReadyFolder.path))

            #expect(opened.reading.position == savedPosition)
            #expect(opened.preferences == savedPrefs)
            #expect(try opened.publication.package.nodes(at: "OPS/Text/ch1.xhtml") == expectedCh1Nodes)
            #expect(try opened.publication.package.nodes(at: targetPath) == expectedCh2Nodes)

            let ch1Data = try EPUBResourceStore.data(path: "OPS/Text/ch1.xhtml", publication: opened.publication)
            let ch1Text = String(decoding: ch1Data, as: UTF8.self)
            #expect(ch1Text.contains("data-yj-author-style=\"true\""))
            #expect(ch1Text.contains("data-yj-author-scope=\""))
            let fontRes = try #require(opened.publication.package.resource(at: "OPS/Fonts/book.ttf"))
            #expect(fontRes.mediaType == "font/ttf")
            #expect(!(try EPUBResourceStore.data(path: "OPS/Fonts/book.ttf", publication: opened.publication)).isEmpty)

            let storedSource = try await f.store.epubFileURL(bookID: bookID)
            #expect(try Data(contentsOf: storedSource) == originalArchiveBytes)
            try await opened.abandon()

            // Second open reuses migrated Ready directory without rebuilding.
            let reopened = try await freshService.openEPUB(id: bookID)
            #expect(reopened.reusedResources)
            #expect(!reopened.openingTimings.readyPreparationOccurred)
            #expect(reopened.publication.package.authorStyleRevision == EPUBFormat.authorStyleRevision)
            #expect(reopened.publication.resourceRoot == opened.publication.resourceRoot)
            #expect(reopened.reading.position == savedPosition)
            try await reopened.abandon()
        }

        // Case B: Legacy DB package WITHOUT Ready (ready == nil, missing authorStyleRevision).
        do {
            let f = try EPUBLibraryFixture()
            defer { f.remove() }

            let archive = try writeStyledFontEPUB(at: f.root.appendingPathComponent("legacy-no-ready.epub"))
            let originalArchiveBytes = try Data(contentsOf: archive)
            let receipt = try await installLegacyWithoutReady(f, archive: archive)
            let bookID = receipt.book.id

            try await rewriteMetadataAsPreAuthorStyleLegacy(in: f.managed, bookID: bookID)
            let before = try await f.store.storedEPUBSnapshot(bookID: bookID)
            #expect(before.package.ready == nil)
            #expect(before.package.authorStyleRevision == nil)
            #expect(!before.package.textNodes.isEmpty)
            #expect(try await f.store.referencedEPUBReadyDirectories().isEmpty)

            let savedPosition = EPUBReadingPosition(
                bookID: bookID,
                versionID: before.package.versionID,
                path: "OPS/Text/ch1.xhtml",
                node: 1,
                utf16Offset: 1
            )
            let savedPrefs = ReaderPreferences(fontSize: 22, lineSpacing: 9, theme: .light)
            try await persistReadingProgress(
                store: f.store,
                snapshot: before,
                position: savedPosition,
                preferences: savedPrefs
            )

            let opened = try await f.service.openEPUB(id: bookID)
            #expect(opened.openingTimings.readyPreparationOccurred)
            #expect(opened.openingTimings.chapterIndexedMetadata)
            #expect(!opened.reusedResources)
            #expect(opened.publication.package.authorStyleRevision == EPUBFormat.authorStyleRevision)
            let readyDir = try #require(opened.publication.package.ready?.directory)
            #expect(try await f.store.referencedEPUBReadyDirectories() == [readyDir])
            #expect(opened.reading.position == savedPosition)
            #expect(opened.preferences == savedPrefs)
            for chapter in before.package.spine {
                #expect(try opened.publication.package.nodes(at: chapter) == before.package.textNodes[chapter])
            }
            #expect(opened.publication.package.resource(at: "OPS/Fonts/book.ttf")?.mediaType == "font/ttf")
            #expect(try Data(contentsOf: await f.store.epubFileURL(bookID: bookID)) == originalArchiveBytes)
            try await opened.abandon()

            let again = try await f.service.openEPUB(id: bookID)
            #expect(again.reusedResources && !again.openingTimings.readyPreparationOccurred)
            #expect(again.reading.position == savedPosition)
            try await again.abandon()
        }

        // Case C: Tampered original archive fails source verification during author-style migration.
        do {
            let f = try EPUBLibraryFixture()
            defer { f.remove() }

            let archive = try writeStyledFontEPUB(at: f.root.appendingPathComponent("tampered-source.epub"))
            let receipt = try await f.install(archive)
            let bookID = receipt.book.id
            try await rewriteMetadataAsPreAuthorStyleLegacy(in: f.managed, bookID: bookID)
            let legacySnapshot = try await f.store.storedEPUBSnapshot(bookID: bookID)

            let savedPosition = EPUBReadingPosition(
                bookID: bookID,
                versionID: legacySnapshot.package.versionID,
                path: "OPS/Text/ch1.xhtml",
                node: 0,
                utf16Offset: 1
            )
            try await persistReadingProgress(
                store: f.store,
                snapshot: legacySnapshot,
                position: savedPosition,
                preferences: ReaderPreferences()
            )

            let storedSource = try await f.store.epubFileURL(bookID: bookID)
            let intactBytes = try Data(contentsOf: storedSource)
            var corruptedBytes = intactBytes
            corruptedBytes[corruptedBytes.count - 1] ^= 0xFF
            try corruptedBytes.write(to: storedSource)

            let pool = EPUBContentPool()
            let readyRoot = await f.store.epubReadyURL()
            let work = await f.store.epubWorkURL(id: UUID())
            await #expect(throws: LibraryError.changedFile) {
                _ = try await pool.upgradeAuthorStyles(archive: storedSource, expected: legacySnapshot.package, root: readyRoot, work: work)
            }
            await #expect(throws: LibraryError.changedFile) {
                _ = try await f.service.openEPUB(id: bookID)
            }
            #expect(try await f.store.storedEPUBSnapshot(bookID: bookID).package.authorStyleRevision == nil)

            try intactBytes.write(to: storedSource)
            let recovered = try await f.service.openEPUB(id: bookID)
            #expect(recovered.publication.package.authorStyleRevision == EPUBFormat.authorStyleRevision)
            #expect(recovered.reading.position == savedPosition)
            try await recovered.abandon()
        }
    }

    @Test func authorStyleMigrationValidationRejectsCoordinateMetadataResourceAndRevisionMismatches() throws {
        let f = try EPUBLibraryFixture()
        defer { f.remove() }

        let ttf = makeMinimalTTF()
        let otf = makeMinimalOTF()
        let png = try EPUBLibraryFixture.image(width: 8, height: 8)
        let imgHash = EPUBResourceStore.digest(png)
        let ttfHash = EPUBResourceStore.digest(ttf)
        let otfHash = EPUBResourceStore.digest(otf)

        let nodes: [String: [String]] = [
            "OPS/ch1.xhtml": ["Chapter 1", "Body A😀e\u{301}"],
            "OPS/ch2.xhtml": ["Chapter 2", "Body two"]
        ]
        let nav = [
            EPUBNavigationItem(title: "Ch1", path: "OPS/ch1.xhtml", fragment: "h1", depth: 0),
            EPUBNavigationItem(title: "Ch2", path: "OPS/ch2.xhtml", fragment: nil, depth: 0)
        ]
        let prevResources = [
            EPUBResource(path: "OPS/ch1.xhtml", mediaType: "application/xhtml+xml", sha256: String(repeating: "1", count: 64), byteCount: 100),
            EPUBResource(path: "OPS/ch2.xhtml", mediaType: "application/xhtml+xml", sha256: String(repeating: "2", count: 64), byteCount: 110),
            EPUBResource(path: "OPS/cover.png", mediaType: "image/png", sha256: imgHash, byteCount: png.count)
        ]
        let nextResources = [
            EPUBResource(path: "OPS/ch1.xhtml", mediaType: "application/xhtml+xml", sha256: String(repeating: "a", count: 64), byteCount: 240),
            EPUBResource(path: "OPS/ch2.xhtml", mediaType: "application/xhtml+xml", sha256: String(repeating: "b", count: 64), byteCount: 260),
            EPUBResource(path: "OPS/cover.png", mediaType: "image/png", sha256: imgHash, byteCount: png.count),
            EPUBResource(path: "OPS/book.ttf", mediaType: "font/ttf", sha256: ttfHash, byteCount: ttf.count),
            EPUBResource(path: "OPS/book.otf", mediaType: "font/otf", sha256: otfHash, byteCount: otf.count)
        ]

        func makePkg(
            sourceSHA256: String = String(repeating: "c", count: 64),
            parserVersion: String = EPUBFormat.parserVersion,
            title: String = "Migration Validate Book",
            spine: [String] = ["OPS/ch1.xhtml", "OPS/ch2.xhtml"],
            navigation: [EPUBNavigationItem] = nav,
            resources: [EPUBResource] = prevResources,
            textNodes: [String: [String]] = nodes,
            coverPath: String? = "OPS/cover.png",
            ready: EPUBReadyReference? = nil,
            authorStyleRevision: Int? = nil
        ) -> EPUBPackage {
            EPUBPackage(
                sourceSHA256: sourceSHA256,
                parserVersion: parserVersion,
                title: title,
                spine: spine,
                navigation: navigation,
                resources: resources,
                textNodes: textNodes,
                coverPath: coverPath,
                ready: ready,
                authorStyleRevision: authorStyleRevision
            )
        }

        let prevInline = makePkg()
        let readyFolder = f.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: readyFolder, withIntermediateDirectories: false)
        let prevReady = try EPUBReadyArtifact.writeNodes(package: prevInline, folder: readyFolder)
        let validReplacement = makePkg(
            resources: nextResources,
            authorStyleRevision: EPUBFormat.authorStyleRevision
        )
        let compactReplacementFolder = f.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: compactReplacementFolder, withIntermediateDirectories: false)
        let validCompactReplacement = try EPUBReadyArtifact.writeNodes(package: validReplacement, folder: compactReplacementFolder)

        // Valid migrations succeed (for both ready == nil and ready != nil previous packages).
        try EPUBAuthorStyleMigration.validate(previous: prevInline, replacement: validReplacement)
        try EPUBAuthorStyleMigration.validate(previous: prevReady, replacement: validReplacement)
        try EPUBAuthorStyleMigration.validate(previous: prevReady, replacement: validCompactReplacement)
        let droppedChapter = makePkg(resources: Array(nextResources.dropFirst()), authorStyleRevision: EPUBFormat.authorStyleRevision)
        var changedTypeResources = nextResources
        changedTypeResources[0] = EPUBResource(path: "OPS/ch1.xhtml", mediaType: "image/png",
                                               sha256: nextResources[0].sha256, byteCount: nextResources[0].byteCount)
        let changedChapterType = makePkg(resources: changedTypeResources, authorStyleRevision: EPUBFormat.authorStyleRevision)
        for badResourceSet in [droppedChapter, changedChapterType] {
            #expect(throws: EPUBError.corruptResource) {
                try EPUBAuthorStyleMigration.validate(previous: prevInline, replacement: badResourceSet)
            }
        }

        // 1. Text node / coordinate digest changes (modified text or missing chapter) must fail.
        var mutatedNodes = nodes
        mutatedNodes["OPS/ch1.xhtml"] = ["Chapter 1", "Body MODIFIED"]
        let badTextPkg = makePkg(resources: nextResources, textNodes: mutatedNodes, authorStyleRevision: EPUBFormat.authorStyleRevision)
        var missingNodes = nodes
        missingNodes.removeValue(forKey: "OPS/ch2.xhtml")
        let missingTextPkg = makePkg(resources: nextResources, textNodes: missingNodes, authorStyleRevision: EPUBFormat.authorStyleRevision)
        for badText in [badTextPkg, missingTextPkg] {
            #expect(throws: EPUBError.corruptResource) {
                try EPUBAuthorStyleMigration.validate(previous: prevInline, replacement: badText)
            }
            #expect(throws: EPUBError.corruptResource) {
                try EPUBAuthorStyleMigration.validate(previous: prevReady, replacement: badText)
            }
        }

        let prevRef = try #require(prevReady.ready)
        var badChapters = prevRef.chapters
        let ch1Ref = try #require(badChapters["OPS/ch1.xhtml"])
        badChapters["OPS/ch1.xhtml"] = EPUBReadyReference.Chapter(
            offset: ch1Ref.offset,
            bytes: ch1Ref.bytes,
            sha256: String(repeating: "f", count: 64)
        )
        let tamperedReadyRef = EPUBReadyReference(
            revision: prevRef.revision,
            directory: prevRef.directory,
            legacyPackageSHA256: prevRef.legacyPackageSHA256,
            nodeBytes: prevRef.nodeBytes,
            nodeSHA256: prevRef.nodeSHA256,
            chapters: badChapters
        )
        let badReadyPrev = prevInline.withReady(tamperedReadyRef)
        #expect(throws: EPUBError.corruptResource) {
            try EPUBAuthorStyleMigration.validate(previous: badReadyPrev, replacement: validReplacement)
        }

        // 2. Source, parserVersion, title, spine, navigation, and coverPath changes must fail.
        let metadataMutants: [EPUBPackage] = [
            makePkg(sourceSHA256: String(repeating: "d", count: 64), resources: nextResources, authorStyleRevision: EPUBFormat.authorStyleRevision),
            makePkg(parserVersion: "epub-dom-v2", resources: nextResources, authorStyleRevision: EPUBFormat.authorStyleRevision),
            makePkg(title: "Changed Title", resources: nextResources, authorStyleRevision: EPUBFormat.authorStyleRevision),
            makePkg(spine: ["OPS/ch2.xhtml", "OPS/ch1.xhtml"], resources: nextResources, authorStyleRevision: EPUBFormat.authorStyleRevision),
            makePkg(navigation: [EPUBNavigationItem(title: "Renamed", path: "OPS/ch1.xhtml", fragment: "h1", depth: 0)], resources: nextResources, authorStyleRevision: EPUBFormat.authorStyleRevision),
            makePkg(resources: nextResources, coverPath: nil, authorStyleRevision: EPUBFormat.authorStyleRevision)
        ]
        for mutant in metadataMutants {
            #expect(throws: EPUBError.corruptResource) {
                try EPUBAuthorStyleMigration.validate(previous: prevInline, replacement: mutant)
            }
        }

        // 3. Non-XHTML resource changes, unexpected added resources, and duplicate resource paths must fail.
        let resourceMutants: [EPUBPackage] = [
            // Missing cover image in replacement
            makePkg(resources: Array(nextResources.prefix(2)), authorStyleRevision: EPUBFormat.authorStyleRevision),
            // Altered cover image sha256
            makePkg(resources: [
                nextResources[0], nextResources[1],
                EPUBResource(path: "OPS/cover.png", mediaType: "image/png", sha256: String(repeating: "9", count: 64), byteCount: png.count)
            ], authorStyleRevision: EPUBFormat.authorStyleRevision),
            // Added text/css resource
            makePkg(resources: nextResources + [
                EPUBResource(path: "OPS/style.css", mediaType: "text/css", sha256: String(repeating: "3", count: 64), byteCount: 32)
            ], authorStyleRevision: EPUBFormat.authorStyleRevision),
            // Added non-ttf/otf font resource
            makePkg(resources: nextResources + [
                EPUBResource(path: "OPS/book.woff", mediaType: "font/woff", sha256: String(repeating: "4", count: 64), byteCount: 32)
            ], authorStyleRevision: EPUBFormat.authorStyleRevision),
            // Duplicate resource path in replacement
            makePkg(resources: nextResources + [nextResources[2]], authorStyleRevision: EPUBFormat.authorStyleRevision)
        ]
        for mutant in resourceMutants {
            #expect(throws: EPUBError.corruptResource) {
                try EPUBAuthorStyleMigration.validate(previous: prevInline, replacement: mutant)
            }
        }
        let duplicatePrev = makePkg(resources: prevResources + [prevResources[2]])
        #expect(throws: EPUBError.corruptResource) {
            try EPUBAuthorStyleMigration.validate(previous: duplicatePrev, replacement: validReplacement)
        }
        // 4. Disallow non-nil previous revision and unknown replacement revision.
        for badPrevRev in [0, 1, 2, -1] {
            let badPrev = makePkg(authorStyleRevision: badPrevRev)
            #expect(throws: EPUBError.corruptResource) {
                try EPUBAuthorStyleMigration.validate(previous: badPrev, replacement: validReplacement)
            }
        }
        let badReplRevisions: [Int?] = [nil, 0, 2, 99, -1]
        for badReplRev in badReplRevisions {
            let badRepl = makePkg(resources: nextResources, authorStyleRevision: badReplRev)
            #expect(throws: EPUBError.corruptResource) {
                try EPUBAuthorStyleMigration.validate(previous: prevInline, replacement: badRepl)
            }
        }
    }

    @Test func failedAuthorStyleMigrationPreservesPreviousStorageProgressAndArchive() async throws {
        // Test failure preservation for BOTH ready != nil and ready == nil legacy packages.
        for hasLegacyReady in [true, false] {
            let f = try EPUBLibraryFixture()
            defer { f.remove() }

            let archive = try writeStyledFontEPUB(at: f.root.appendingPathComponent("rollback-\(hasLegacyReady).epub"))
            let receipt: ImportReceipt
            if hasLegacyReady {
                receipt = try await f.install(archive)
            } else {
                receipt = try await installLegacyWithoutReady(f, archive: archive)
            }
            let bookID = receipt.book.id

            try await rewriteMetadataAsPreAuthorStyleLegacy(in: f.managed, bookID: bookID)
            let before = try await f.store.storedEPUBSnapshot(bookID: bookID)
            let savedPosition = EPUBReadingPosition(
                bookID: bookID,
                versionID: before.package.versionID,
                path: "OPS/Text/ch2.xhtml",
                node: 0,
                utf16Offset: 1,
                viewportOffset: 18
            )
            let savedPrefs = ReaderPreferences(fontSize: 28, lineSpacing: 12, theme: .paper)
            try await persistReadingProgress(
                store: f.store,
                snapshot: before,
                position: savedPosition,
                preferences: savedPrefs
            )

            let queue = try DatabaseQueue(path: f.managed.appendingPathComponent("library.sqlite").path)
            let originalMetadata = try #require(try await queue.read { db in
                try Data.fetchOne(db, sql: "SELECT metadata FROM epubPackages WHERE bookID=?", arguments: [bookID])
            })
            let originalProgress = try #require(try await queue.read { db in
                try Data.fetchOne(db, sql: "SELECT anchor FROM epubProgress WHERE bookID=?", arguments: [bookID])
            })
            let originalReadyDirs = try await f.store.referencedEPUBReadyDirectories()
            let readyRoot = await f.store.epubReadyURL()
            let existingFoldersBefore = try listUUIDFolders(under: readyRoot)
            let storedSource = try await f.store.epubFileURL(bookID: bookID)
            let originalArchiveBytes = try Data(contentsOf: storedSource)

            // Inject deterministic SQLite abort on metadata update during migration publication.
            try await queue.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_author_style_migration
                    BEFORE UPDATE OF metadata ON epubPackages
                    BEGIN
                        SELECT RAISE(ABORT, 'synthetic author style migration failure');
                    END
                    """)
            }

            await #expect(throws: (any Error).self) {
                _ = try await f.service.openEPUB(id: bookID)
            }

            // Old metadata, ready references/files, progress, activeSession, and source archive must remain intact.
            let afterFailureMetadata = try #require(try await queue.read { db in
                try Data.fetchOne(db, sql: "SELECT metadata FROM epubPackages WHERE bookID=?", arguments: [bookID])
            })
            let afterFailureProgress = try #require(try await queue.read { db in
                try Data.fetchOne(db, sql: "SELECT anchor FROM epubProgress WHERE bookID=?", arguments: [bookID])
            })
            let activeSession = try await queue.read { db in
                try String.fetchOne(db, sql: "SELECT activeSession FROM books WHERE id=?", arguments: [bookID])
            }
            #expect(afterFailureMetadata == originalMetadata)
            #expect(afterFailureProgress == originalProgress)
            #expect(activeSession == nil)
            #expect(try await f.store.referencedEPUBReadyDirectories() == originalReadyDirs)
            #expect(try listUUIDFolders(under: readyRoot) == existingFoldersBefore)
            #expect(try Data(contentsOf: storedSource) == originalArchiveBytes)

            // Once the transient DB failure clears, reopening migrates cleanly and preserves reading progress.
            try await queue.write { db in
                try db.execute(sql: "DROP TRIGGER reject_author_style_migration")
            }
            let recovered = try await f.service.openEPUB(id: bookID)
            #expect(recovered.publication.package.authorStyleRevision == EPUBFormat.authorStyleRevision)
            #expect(recovered.reading.position == savedPosition)
            #expect(recovered.preferences == savedPrefs)
            #expect(recovered.openingTimings.readyPreparationOccurred)
            if let oldDir = originalReadyDirs.first {
                let newDir = try #require(recovered.publication.package.ready?.directory)
                #expect(newDir != oldDir)
                #expect(!FileManager.default.fileExists(atPath: readyRoot.appendingPathComponent(oldDir).path))
            }
            try await recovered.abandon()
        }
    }

    // MARK: - Helpers

    private func writeStyledFontEPUB(at url: URL) throws -> URL {
        let ttf = makeMinimalTTF()
        let png = try EPUBLibraryFixture.image(width: 32, height: 32)
        let css = """
        @font-face {
            font-family: "BookFont";
            src: url("../Fonts/book.ttf") format("truetype");
        }
        p.lead {
            font-family: "BookFont", serif;
            text-indent: 2em;
            color: #223344;
        }
        """
        let ch1 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Ch1</title><link rel="stylesheet" type="text/css" href="../Styles/book.css"/></head>
        <body>
            <h1 id="h1">Chapter One</h1>
            <p class="lead" style="margin-bottom: 12px;">A😀e\u{301} styled first chapter.</p>
            <p><img src="../Images/pic.png" alt="Pic"/></p>
        </body>
        </html>
        """
        let ch2 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Ch2</title><style>p { color: #334455; }</style></head>
        <body>
            <h1 id="h2">Chapter Two</h1>
            <p>Second chapter body text.</p>
        </body>
        </html>
        """
        return try EPUBTestSupport.writeEPUB3(
            at: url,
            title: "Synthetic Styled EPUB",
            chapters: [
                EPUBSyntheticChapter(id: "c1", path: "Text/ch1.xhtml", title: "Ch1", headingID: "h1", bodyXHTML: ch1),
                EPUBSyntheticChapter(id: "c2", path: "Text/ch2.xhtml", title: "Ch2", headingID: "h2", bodyXHTML: ch2)
            ],
            coverData: png,
            coverHref: "Images/cover.png",
            coverMediaType: "image/png",
            manifestExtra: """
            <item id="css1" href="Styles/book.css" media-type="text/css"/>
            <item id="font1" href="Fonts/book.ttf" media-type="font/ttf"/>
            <item id="pic1" href="Images/pic.png" media-type="image/png"/>
            """,
            extraEntries: [
                ("OPS/Styles/book.css", Data(css.utf8)),
                ("OPS/Fonts/book.ttf", ttf),
                ("OPS/Images/pic.png", png)
            ]
        )
    }

    private func installLegacyWithoutReady(_ f: EPUBLibraryFixture, archive: URL) async throws -> ImportReceipt {
        let ticket = UUID()
        try await f.store.beginImport(ticket)
        let staging = await f.store.epubStagingURL(ticket: ticket)
        try FileManager.default.copyItem(at: archive, to: staging)
        let work = await f.store.epubWorkURL(id: ticket)
        defer { try? FileManager.default.removeItem(at: work) }
        let package = try EPUBPackageParser.parse(archiveURL: staging, destination: work)
        let bytes = try Data(contentsOf: staging).count
        let book = LibraryBook(
            id: package.sourceSHA256,
            title: package.title,
            encodingRaw: "epub",
            versionID: package.versionID,
            byteCount: bytes,
            utf16Count: 0,
            format: .epub
        )
        return try await f.store.commitEPUB(ticket: ticket, proposed: book, package: package, cover: nil)
    }

    private func rewriteMetadataAsPreAuthorStyleLegacy(in managedRoot: URL, bookID: String) async throws {
        let queue = try DatabaseQueue(path: managedRoot.appendingPathComponent("library.sqlite").path)
        let raw = try #require(try await queue.read { db in
            try Data.fetchOne(db, sql: "SELECT metadata FROM epubPackages WHERE bookID=?", arguments: [bookID])
        })
        guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw EPUBError.corruptResource
        }
        obj.removeValue(forKey: "authorStyleRevision")
        if var resources = obj["resources"] as? [[String: Any]] {
            // Strip font entries and replace XHTML digest/byteCount to match unstyled legacy parser output.
            resources = resources.compactMap { entry in
                guard let mediaType = entry["mediaType"] as? String else { return entry }
                if mediaType == "font/ttf" || mediaType == "font/otf" {
                    return nil
                }
                if mediaType == "application/xhtml+xml" {
                    var updated = entry
                    updated["sha256"] = String(repeating: "0", count: 64)
                    updated["byteCount"] = 128
                    return updated
                }
                return entry
            }
            obj["resources"] = resources
        }
        let updated = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try await queue.write { db in
            try db.execute(sql: "UPDATE epubPackages SET metadata=? WHERE bookID=?", arguments: [updated, bookID])
        }
    }

    private func persistReadingProgress(
        store: LibraryStore,
        snapshot: EPUBMetadataSnapshot,
        position: EPUBReadingPosition,
        preferences: ReaderPreferences
    ) async throws {
        let bookID = snapshot.package.sourceSHA256
        let permit = try await store.reserveReaderOpen(bookID: bookID)
        let start = try await store.beginEPUB(permit, snapshot: snapshot)
        try await store.confirmReaderOpen(permit, session: start.session)
        await store.endReaderOpen(permit)
        let token = try await store.beginEPUBNavigation(session: start.session, path: position.path)
        #expect(try await store.markEPUBReady(session: start.session, token: token))
        try await store.finishEPUB(
            session: start.session,
            position: position,
            sequence: 1,
            token: token,
            preferences: preferences
        )
    }

    private func jsonStrippingAuthorStyleRevision(_ data: Data, setExplicitNull: Bool) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EPUBError.corruptResource
        }
        if setExplicitNull {
            obj["authorStyleRevision"] = NSNull()
        } else {
            obj.removeValue(forKey: "authorStyleRevision")
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private func listUUIDFolders(under root: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return Set(items.map(\.lastPathComponent).filter { UUID(uuidString: $0) != nil })
    }

    private func makeMinimalTTF() -> Data {
        makeMinimalSFNT(version: 0x00010000, outlineTag: "glyf", includeLoca: true)
    }

    private func makeMinimalOTF() -> Data {
        makeMinimalSFNT(version: 0x4F54544F, outlineTag: "CFF ", includeLoca: false)
    }

    private func makeMinimalSFNT(version: UInt32, outlineTag: String, includeLoca: Bool) -> Data {
        var head = Data(repeating: 0, count: 54)
        let magic: UInt32 = 0x5F0F3CF5
        head[12] = UInt8((magic >> 24) & 0xFF)
        head[13] = UInt8((magic >> 16) & 0xFF)
        head[14] = UInt8((magic >> 8) & 0xFF)
        head[15] = UInt8(magic & 0xFF)

        var tables: [(String, Data)] = [
            ("head", head),
            ("hhea", Data(repeating: 0, count: 36)),
            ("maxp", Data(repeating: 0, count: 6)),
            ("name", Data(repeating: 0, count: 8)),
            (outlineTag, Data(repeating: 0x01, count: 16))
        ]
        if includeLoca {
            tables.append(("loca", Data(repeating: 0, count: 4)))
        }
        tables.sort { $0.0 < $1.0 }

        let numTables = tables.count
        var out = Data()
        appendUInt32BE(&out, version)
        appendUInt16BE(&out, UInt16(numTables))
        var maxPow2 = 1
        var entrySelector: UInt16 = 0
        while maxPow2 * 2 <= numTables {
            maxPow2 *= 2
            entrySelector += 1
        }
        let searchRange = UInt16(maxPow2 * 16)
        let rangeShift = UInt16(numTables * 16) - searchRange
        appendUInt16BE(&out, searchRange)
        appendUInt16BE(&out, entrySelector)
        appendUInt16BE(&out, rangeShift)

        var offset = 12 + numTables * 16
        var bodies = Data()
        for (tag, body) in tables {
            out.append(contentsOf: Array(tag.utf8))
            appendUInt32BE(&out, 0)
            appendUInt32BE(&out, UInt32(offset))
            appendUInt32BE(&out, UInt32(body.count))
            bodies.append(body)
            let pad = (4 - (body.count % 4)) % 4
            if pad > 0 { bodies.append(Data(repeating: 0, count: pad)) }
            offset += body.count + pad
        }
        out.append(bodies)
        return out
    }

    private func appendUInt16BE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
