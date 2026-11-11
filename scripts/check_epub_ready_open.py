#!/usr/bin/env python3
"""Source contracts only. No Swift compilation, native execution or phone performance claim."""
from pathlib import Path
import ast
import json
import re
import task3_test_inventory as inventory

ROOT = Path(__file__).resolve().parents[1]
def read(name):
    return (ROOT / name).read_text(encoding="utf-8")
def require(condition, message):
    if not condition:
        raise AssertionError(message)

def main():
    ready = read("Sources/ReaderDomain/EPUB/EPUBReadyArtifact.swift")
    model = read("Sources/ReaderDomain/EPUB/EPUBModels.swift")
    pool = read("Sources/ReaderDomain/EPUB/EPUBContentPool.swift")
    service = read("Sources/ReaderDomain/LibraryService.swift")
    store = read("Sources/ReaderDomain/LibraryStore.swift")
    resources = read("Sources/ReaderDomain/EPUB/EPUBResourceStore.swift")
    verifier = read("Sources/ReaderDomain/EPUB/EPUBPublicationCache.swift")
    snapshot = read("Sources/ReaderDomain/EPUB/EPUBMetadataSnapshot.swift")
    rows = []

    require('case sourceSHA256, parserVersion, title, spine, navigation, resources, textNodes, coverPath, ready' in model,
            "small Ready descriptor must be encoded")
    keys = model.split('private enum CodingKeys', 1)[1].split('}', 1)[0]
    require('chapterNodes' not in keys, "runtime caches cannot enter stored metadata")
    require('textNodes: [:], coverPath: coverPath, ready: reference' in model, "Ready must not carry all inline nodes")
    require('order.count >= 4' in ready and 'maximumBytes = 8 * 1024 * 1024' in ready,
            "decoded chapter cache must remain bounded")
    require('chapter.offset == offset' in ready and 'offset == reference.nodeBytes' in ready,
            "node pack coverage/offsets must be checked")
    rows.append('versioned compact descriptor, exact pack coverage and bounded chapter cache')

    require('metadataSHA256 = EPUBResourceStore.digest(metadata)' in snapshot and 'metadata == current' in snapshot,
            "fresh metadata SHA and transaction byte equality remain mandatory")
    publish = store.split('func publishEPUBReady', 1)[1].split('func storedEPUBSnapshot', 1)[0]
    require('previous.matches(old)' in publish and 'ready.hasSameContent(as: old)' in publish,
            "publish must bind previous bytes and exact semantic index")
    require(publish.index('previous.matches(old)') < publish.index('UPDATE epubPackages SET metadata='),
            "compare before metadata switch")
    require('INSERT INTO epubReadyVersions' in publish and 'try queue.write' in publish,
            "metadata and directory ref must be one transaction")
    require('directory == package.ready?.directory' in store, "database directory reference cannot drift")
    require('v7-epub-ready-versions' in read('Sources/ReaderDomain/LibrarySchema.swift'), "additive migration missing")
    rows.append('fresh-byte publication CAS and additive Ready reference migration')

    for token in ['isRegularFile', 'isSymbolicLink', 'fileSize == resource.byteCount',
                  'data.count == resource.byteCount', 'digest(data) == resource.sha256', 'EPUBResourcePath.canonical']:
        require(token in resources, 'resource verifier missing: ' + token)
    for token in ['verifyNodes(package:', 'verifyManifest(folder:', 'verifyResourcesConcurrently(publication)', 'sourceDigest(archive)']:
        require(token in pool, 'Ready open missing full verification: ' + token)
    require('count == reference.nodeBytes, digest == reference.nodeSHA256' in ready,
            'all node bytes must be checked before opening')
    require('min(4, resources.count)' in verifier and 'by: 4' in verifier and 'try await group.waitForAll()' in verifier,
            'resource concurrency must be bounded and joined')
    require('Task.checkCancellation()' in verifier and 'EPUBResourceStore.data(resource: resources[index]' in verifier,
            'parallel lanes must use original verifier and cancellation')
    rows.append('full source/manifest/nodepack/resource SHA and bounded joined resource lanes')

    acquire = pool.split('func acquireReady', 1)[1].split('func rebuildReady', 1)[0]
    require(acquire.index('let lease = grant(') < acquire.index('try await EPUBPublicationCache.verifyResourcesConcurrently'),
            'resource version must be pinned before actor suspension')
    require('await lease.release()' in acquire, 'failed verify must release its pin')
    require('!referenced.contains(folder.lastPathComponent), entries[folder] == nil' in pool,
            'reconciliation must protect referenced and pending live versions')
    require('entry.tokens.isEmpty' in pool and 'entry.retired || (!entry.persistent && !entry.retained)' in pool,
            'persistent and active versions cannot be idle-evicted')
    require('previous.package.ready?.directory' in service and 'await staged.release()' in service,
            'publication must retire only previous generation and release staging')
    rows.append('pending/publication leases, persistent ownership and generation-isolated reclamation')

    for path in ['App/EPUB/EPUBLocationScript.swift', 'App/EPUB/EPUBChapterWindow.swift',
                 'Sources/ReaderDomain/EPUB/EPUBReadingPosition.swift']:
        require('.nodes(at:' in read(path) and '.textNodes[' not in read(path), 'inline node consumer: ' + path)
    require('try publication.package.nodes(at: firstPath)' in service and 'try authority.package.nodes(at: path)' in store,
            'current chapter must be prepared on service/store actors')
    cache = read('App/EPUB/EPUBWarmRendererCache.swift')
    require('96 * 1024 * 1024' in cache and 'totalRenderers = 3' in cache, 'renderer budget changed')
    script = read('App/EPUB/EPUBLocationScript.swift')
    require('function trimParkedWindow()' in script and 'state.chapters = previous' in script,
            'park slimming must have a DOM-preserving rollback')
    require('(img.naturalWidth || 0) * (img.naturalHeight || 0) * 4' in script,
            'image estimate must not be artificially lowered')
    rows.append('all node consumers routed by chapter; unchanged renderer budgets and pixel-preserving park rollback')

    report = inventory.validate_source(ROOT)
    require(report['selected'] == 236 and report['selected_executions'] == 237, 'inventory mismatch')
    require(len(inventory.FILES['ReaderDomainTests/EPUBReadyTests.swift'].split()) == 7, 'seven new native declarations required')
    for name in ['legacyMigrationPreservesProgressPreferencesAndOriginal',
                 'readyUnvisitedNodeDamageIsDetectedBeforeOpenAndRepairedWithLeaseIsolation',
                 'readyPublicationRollbackAndReconciliationProtectLiveVersions',
                 'readyManifestMutationCannotBeBlessedByRepair',
                 'boundedParallelVerificationMatchesSerialIntegrityAndCancellation']:
        require('@Test func ' + name in read('Tests/ReaderDomainTests/EPUBReadyTests.swift'), 'missing native declaration: ' + name)
    for path in ['scripts/check_epub_ready_open.py', 'scripts/task3_test_inventory.py']:
        ast.parse(read(path), filename=path)
    rows.append('236 declaration identities / 237 expansions; seven new native declarations (NOT executed)')
    print(json.dumps(dict(kind='SOURCE_CONTRACTS_NOT_NATIVE',passed=True,checks=rows,
                         swift_compiled=False,native_executed=0,phone_performance_verified=False),ensure_ascii=False,indent=2))

if __name__ == '__main__':
    main()
