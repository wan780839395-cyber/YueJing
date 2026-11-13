# EPUB compatibility and preparation repair

Candidate: 0.2.18 / build 20, based on `b890588f43870bf6f91ef4f0729ee42a6b520b28`.
This document describes the implementation and verification contract, not device acceptance.

## Changes and boundaries

| Authorized area | Implementation / retained boundary |
| --- | --- |
| Failure classification | Fixed preparation stages, numeric chapter/output/path-cache/RSS high-water counters, EPUB safe failure categories. Migration inconsistency has a separate stage/reason. No title, path, source hash, text or automatic telemetry. |
| External references | Ordinary http/https/mailto/tel/protocol-relative anchors lose href but retain text. Unused head hints are never emitted or fetched. Active URLs, events and author scripts remain rejected. |
| Navigation | Bad local links lose interaction. Valid EPUB3 nav supersedes obsolete NCX. Unusable optional navigation falls back to verified spine. Required chapters never disappear. XML entity/DOCTYPE preflight, path integrity and cancellation remain enforced. |
| Optional styles/fonts | Lexical/structural CSS and audited complexity failures roll back the chapter's style/font capabilities. Invalid SFNT structure is classified only after safe bounded reads; it never reaches a font decoder. Missing resources remain localized warnings. Path, IO, size mismatch and hard byte limits are not swallowed. |
| Static SVG | The existing inert single-raster wrapper accepts the OPF svg hint; arbitrary vector SVG, scripts and MathML remain unsupported. |
| Protection metadata | Only exact IDPF/Adobe font-obfuscation metadata for manifest font objects may omit fonts. No decryption. Rights metadata, unknown algorithms, encrypted text and unknown encryption structures remain unsupported. |
| Empty pages/images | Empty pages keep spine identity with one stable placeholder anchor. Actual missing/corrupt body images still fail: no implicit incomplete-reading mode. Unmanifested, present PNG/JPEG files may join the derived resource list only after safe path, byte/type/pixel/full-decode validation. |
| Old markup/package defects | Inert legacy presentation tags become deterministic div/span/s containers; unsupported attributes are dropped. Mimetype remains exact after bounded whitespace normalization and normal ZIP integrity checks. Empty titles use a deterministic fallback. |
| TXT capability gaps | Strict byte-preserving decode and existing ambiguity preview/confirmation remain unchanged. BOM-less UTF16 manual selection and Big5/Shift-JIS/UTF32 remain explicit capability gaps, not 'security failures'. No implicit lossy rescue or progress reinterpretation is introduced by this EPUB repair. A manual picker with independently validated source/coordinate versions is not simulated by weakening the current candidate gate. |
| Budgets/new formats | All existing archive, chapter, image, font, parser and test time limits remain. No WOFF/WOFF2 decompressor, general SVG, DRM, new encoding or silent text-only mode. |

## Preparation cost

- Optional resource presence/symlink-chain checks are cached only within one private package extraction, with a 4096-entry retention cap. Overflow does more validation; it does not reject a book or skip checks.
- A chapter's sanitized XHTML is written to the unpublished work directory immediately. No full-book XHTML dictionary is retained. Text nodes and lightweight metadata remain full-book during initial preparation; this is not a claim of fully streamed import or a hard RSS ceiling.
- An autorelease pool drains per-chapter Foundation temporaries. Final resource SHA, ZIP CRC and complete source SHA remain unchanged.
- The existing synthetic 1633-chapter regression now has 96 font-face rules and sizeable original text. It records elapsed time, process RSS high-water and actual filesystem-check counts. These are simulator/process measurements, not iPhone Jetsam attribution or a before/after device benchmark.

## Existing-library protection

Author-style revision advances to 3; nil/1/2 remain migratable. Source/book identity, position-unit and parser text-coordinate version do not change. Publication still requires exact old text-node digests, spine/navigation and non-XHTML resource identity, followed by the existing CAS/lease transaction. A mismatch fails without replacing old metadata or progress. Failure/cancellation deletes only the current work/version directory; existing referenced/leased Ready reclamation is unchanged.

Use an overlay install. Never uninstall, clear the library, delete books, alter the original archive or force reimport to manufacture success.

## Verification contract

The exact fresh Domain/Host test identities and allowed files are frozen in `scripts/epub_author_layout_scope.json`. Existing negative inputs whose contract changed are retained and now assert inert output, warnings and empty capabilities; dangerous/path/CRC/content-loss tests remain negative. No default full TXT/UI rerun and no historical result relabeled as a new run.

Selected tests, device Release compilation, strict IPA identity/resource/architecture/dependency checks, and real-device acceptance are separate outcomes. Independent failures continue; missing or failed test evidence never becomes formal qualification. Any diagnostic artifact must be explicitly labeled as such. Results and raw failures stay in ignored artifacts; private books are never uploaded.

Real-device opening of the existing record, preservation of the old position, reimport, responsiveness and crash disappearance remain pending until actual device evidence is obtained. No Jetsam/watchdog cause is asserted without its corresponding evidence.
