#!/usr/bin/env python3
"""Deterministic, stdlib-only synthetic TrueType font (.ttf) generator for YueJing EPUB tests.

Generates a minimal, fully spec-compliant SFNT TrueType font containing three
original geometric glyphs:
  - GID 0: .notdef (hollow geometric frame, advanceWidth=1000, lsb=100)
  - GID 1: space  (U+0020, empty outline,        advanceWidth=1000, lsb=0)
  - GID 2: A      (U+0041, wide geometric 'A',   advanceWidth=2500, lsb=100)

Tables included (ASCII sorted):
  OS/2, cmap, glyf, head, hhea, hmtx, loca, maxp, name, post

No third-party tools, network access, or system fonts are used.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import struct
import sys
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple

UNITS_PER_EM = 1000
ASCENDER = 800
DESCENDER = -200
LINE_GAP = 0
FIXED_LONGDATETIME = 3810000000  # Deterministic fixed epoch seconds since 1904-01-01.

FONT_FAMILY = "YueJingTestGeometric"
FONT_SUBFAMILY = "Regular"
FONT_UNIQUE_ID = "YueJingTestGeometric-1.0"
FONT_FULL_NAME = "YueJingTestGeometric Regular"
FONT_VERSION = "Version 1.0"
FONT_POSTSCRIPT_NAME = "YueJingTestGeometric-Regular"

# Original geometric contour definitions (x, y) in font units (Y-up).
# Outer contours are clockwise; inner cutout contours are counter-clockwise.
NOTDEF_CONTOURS: Tuple[Tuple[Tuple[int, int], ...], ...] = (
    ((100, 0), (100, 700), (900, 700), (900, 0)),
    ((200, 100), (800, 100), (800, 600), (200, 600)),
)

GLYPH_A_CONTOURS: Tuple[Tuple[Tuple[int, int], ...], ...] = (
    (
        (100, 0),
        (1050, 700),
        (1450, 700),
        (2400, 0),
        (1950, 0),
        (1720, 200),
        (780, 200),
        (550, 0),
    ),
    (
        (920, 320),
        (1580, 320),
        (1250, 560),
    ),
)

HMETRICS: Tuple[Tuple[int, int], ...] = (
    (1000, 100),  # GID 0: .notdef
    (1000, 0),    # GID 1: space
    (2500, 100),  # GID 2: A (distinctively wide 2.5em metric to distinguish from fallback)
)


def _pad4(data: bytes) -> bytes:
    rem = len(data) % 4
    return data if rem == 0 else data + b"\x00" * (4 - rem)


def _pad2(data: bytes) -> bytes:
    return data if len(data) % 2 == 0 else data + b"\x00"


def _calc_checksum(data: bytes) -> int:
    padded = _pad4(data)
    total = 0
    for (word,) in struct.iter_unpack(">I", padded):
        total = (total + word) & 0xFFFFFFFF
    return total


def _signed_area(contour: Sequence[Tuple[int, int]]) -> int:
    area2 = 0
    n = len(contour)
    for i in range(n):
        x1, y1 = contour[i]
        x2, y2 = contour[(i + 1) % n]
        area2 += x1 * y2 - x2 * y1
    return area2


def _encode_simple_glyph(contours: Sequence[Sequence[Tuple[int, int]]]) -> Tuple[bytes, Tuple[int, int, int, int]]:
    assert len(contours) > 0
    all_pts = [pt for c in contours for pt in c]
    xs = [p[0] for p in all_pts]
    ys = [p[1] for p in all_pts]
    xmin, ymin, xmax, ymax = min(xs), min(ys), max(xs), max(ys)

    end_pts: List[int] = []
    running = -1
    for c in contours:
        running += len(c)
        end_pts.append(running)

    out = bytearray()
    out += struct.pack(">5h", len(contours), xmin, ymin, xmax, ymax)
    out += struct.pack(f">{len(end_pts)}H", *end_pts)
    out += struct.pack(">H", 0)  # instructionLength = 0

    # Emit flag = 0x01 (on-curve, explicit 16-bit signed dx and dy) for every point.
    out += bytes([0x01] * len(all_pts))

    dx_bytes = bytearray()
    dy_bytes = bytearray()
    prev_x, prev_y = 0, 0
    for x, y in all_pts:
        dx_bytes += struct.pack(">h", x - prev_x)
        dy_bytes += struct.pack(">h", y - prev_y)
        prev_x, prev_y = x, y

    out += dx_bytes
    out += dy_bytes
    return _pad2(bytes(out)), (xmin, ymin, xmax, ymax)


def _build_glyf_and_loca() -> Tuple[bytes, bytes, Tuple[int, int, int, int]]:
    g0_bytes, b0 = _encode_simple_glyph(NOTDEF_CONTOURS)
    g1_bytes = b""  # space has 0 contours (empty glyf entry)
    g2_bytes, b2 = _encode_simple_glyph(GLYPH_A_CONTOURS)

    off0 = 0
    off1 = len(g0_bytes)
    off2 = off1 + len(g1_bytes)
    off3 = off2 + len(g2_bytes)

    glyf = g0_bytes + g1_bytes + g2_bytes
    assert off3 % 2 == 0 and off1 % 2 == 0 and off2 % 2 == 0
    loca = struct.pack(">4H", off0 // 2, off1 // 2, off2 // 2, off3 // 2)

    bbox = (
        min(b0[0], b2[0]),
        min(b0[1], b2[1]),
        max(b0[2], b2[2]),
        max(b0[3], b2[3]),
    )
    return glyf, loca, bbox


def _build_head(bbox: Tuple[int, int, int, int], checksum_adjustment: int = 0) -> bytes:
    xmin, ymin, xmax, ymax = bbox
    return struct.pack(
        ">2H3I2H2q4h2H3h",
        1,                      # majorVersion
        0,                      # minorVersion
        0x00010000,             # fontRevision (1.0)
        checksum_adjustment,    # checkSumAdjustment
        0x5F0F3CF5,             # magicNumber
        0x0003,                 # flags (baseline at y=0, lsb at x=0)
        UNITS_PER_EM,           # unitsPerEm
        FIXED_LONGDATETIME,     # created
        FIXED_LONGDATETIME,     # modified
        xmin,
        ymin,
        xmax,
        ymax,
        0,                      # macStyle (Regular)
        8,                      # lowestRecPPEM
        2,                      # fontDirectionHint (strongly L->R)
        0,                      # indexToLocFormat (short offsets)
        0,                      # glyphDataFormat
    )


def _build_hhea(bbox_notdef: Tuple[int, int, int, int], bbox_a: Tuple[int, int, int, int]) -> bytes:
    # Metrics across glyphs with outlines (.notdef and A)
    aw_max = max(aw for aw, _ in HMETRICS)
    lsb_min = min(HMETRICS[0][1], HMETRICS[2][1])
    rsb_0 = HMETRICS[0][0] - (HMETRICS[0][1] + (bbox_notdef[2] - bbox_notdef[0]))
    rsb_2 = HMETRICS[2][0] - (HMETRICS[2][1] + (bbox_a[2] - bbox_a[0]))
    rsb_min = min(rsb_0, rsb_2)
    ext_0 = HMETRICS[0][1] + (bbox_notdef[2] - bbox_notdef[0])
    ext_2 = HMETRICS[2][1] + (bbox_a[2] - bbox_a[0])
    xmax_extent = max(ext_0, ext_2)

    return struct.pack(
        ">2H3hH11hH",
        1,              # majorVersion
        0,              # minorVersion
        ASCENDER,       # ascender
        DESCENDER,      # descender
        LINE_GAP,       # lineGap
        aw_max,         # advanceWidthMax
        lsb_min,        # minLeftSideBearing
        rsb_min,        # minRightSideBearing
        xmax_extent,    # xMaxExtent
        1,              # caretSlopeRise
        0,              # caretSlopeRun
        0,              # caretOffset
        0, 0, 0, 0,     # reserved0..3
        0,              # metricDataFormat
        len(HMETRICS),  # numberOfHMetrics
    )


def _build_maxp() -> bytes:
    max_points = max(sum(len(c) for c in NOTDEF_CONTOURS), sum(len(c) for c in GLYPH_A_CONTOURS))
    max_contours = max(len(NOTDEF_CONTOURS), len(GLYPH_A_CONTOURS))
    return struct.pack(
        ">I14H",
        0x00010000,   # version 1.0 (TrueType)
        len(HMETRICS),
        max_points,
        max_contours,
        0,            # maxCompositePoints
        0,            # maxCompositeContours
        2,            # maxZones
        0,            # maxTwilightPoints
        0,            # maxStorage
        0,            # maxFunctionDefs
        0,            # maxInstructionDefs
        0,            # maxStackElements
        0,            # maxSizeOfInstructions
        0,            # maxComponentElements
        0,            # maxComponentDepth
    )


def _build_os2() -> bytes:
    avg_width = sum(aw for aw, _ in HMETRICS) // len(HMETRICS)
    panose = bytes([2, 0, 5, 3, 0, 0, 0, 0, 0, 0])
    vend_id = b"YJTF"
    return struct.pack(
        ">Hh3H11h10s4I4s3H3h2H2I2h3H",
        4,           # version 4 (96 bytes)
        avg_width,   # xAvgCharWidth (1500)
        400,         # usWeightClass (Regular)
        5,           # usWidthClass (Medium/Normal)
        0,           # fsType (Installable embedding)
        650, 600, 0, 75,    # ySubscriptXSize, YSize, XOffset, YOffset
        650, 600, 0, 350,   # ySuperscriptXSize, YSize, XOffset, YOffset
        50, 250,     # yStrikeoutSize, yStrikeoutPosition
        0,           # sFamilyClass
        panose,      # panose[10]
        1, 0, 0, 0,  # ulUnicodeRange1..4 (Basic Latin)
        vend_id,     # achVendID
        0x00C0,      # fsSelection (REGULAR | USE_TYPO_METRICS)
        0x0020,      # usFirstCharIndex (space)
        0x0041,      # usLastCharIndex ('A')
        ASCENDER,    # sTypoAscender
        DESCENDER,   # sTypoDescender
        LINE_GAP,    # sTypoLineGap
        ASCENDER,    # usWinAscent
        abs(DESCENDER),  # usWinDescent
        1, 0,        # ulCodePageRange1..2 (Latin 1)
        500,         # sxHeight
        700,         # sCapHeight
        0,           # usDefaultChar (.notdef)
        0x0020,      # usBreakChar (space)
        0,           # usMaxContext
    )


def _build_hmtx() -> bytes:
    return b"".join(struct.pack(">Hh", aw, lsb) for aw, lsb in HMETRICS)


def _build_cmap() -> bytes:
    # Segment 0: U+0020 -> GID 1 (idDelta = 1 - 0x0020 = -31)
    # Segment 1: U+0041 -> GID 2 (idDelta = 2 - 0x0041 = -63)
    # Segment 2: U+FFFF -> GID 0 (sentinel, idDelta = 1)
    seg_count = 3
    search_range = 4      # 2 * 2^floor(log2(3))
    entry_selector = 1    # floor(log2(3))
    range_shift = 2       # 2*3 - 4
    subtable_len = 14 + seg_count * 8 + 2  # 40 bytes

    fmt4 = struct.pack(
        ">7H3HH3H3h3H",
        4,
        subtable_len,
        0,
        seg_count * 2,
        search_range,
        entry_selector,
        range_shift,
        0x0020, 0x0041, 0xFFFF,  # endCode
        0,                        # reservedPad
        0x0020, 0x0041, 0xFFFF,  # startCode
        1 - 0x0020, 2 - 0x0041, 1,  # idDelta
        0, 0, 0,                  # idRangeOffset
    )
    assert len(fmt4) == subtable_len == 40

    subtable_offset = 4 + 2 * 8  # 20
    header = struct.pack(">2H", 0, 2)
    records = struct.pack(">HHI", 0, 3, subtable_offset) + struct.pack(">HHI", 3, 1, subtable_offset)
    return header + records + fmt4


def _build_name() -> bytes:
    entries = (
        (1, FONT_FAMILY),
        (2, FONT_SUBFAMILY),
        (3, FONT_UNIQUE_ID),
        (4, FONT_FULL_NAME),
        (5, FONT_VERSION),
        (6, FONT_POSTSCRIPT_NAME),
    )

    records_spec: List[Tuple[int, int, int, int, bytes]] = []
    # Platform 1: Macintosh Roman, English (0)
    for name_id, text in entries:
        records_spec.append((1, 0, 0, name_id, text.encode("ascii")))
    # Platform 3: Windows Unicode BMP, English US (0x0409)
    for name_id, text in entries:
        records_spec.append((3, 1, 0x0409, name_id, text.encode("utf-16-be")))

    records_spec.sort(key=lambda r: (r[0], r[1], r[2], r[3]))

    storage = bytearray()
    records_bytes = bytearray()
    for platform_id, encoding_id, language_id, name_id, raw in records_spec:
        offset = len(storage)
        storage += raw
        records_bytes += struct.pack(
            ">6H",
            platform_id,
            encoding_id,
            language_id,
            name_id,
            len(raw),
            offset,
        )

    storage_offset = 6 + len(records_bytes)
    header = struct.pack(">3H", 0, len(records_spec), storage_offset)
    return header + bytes(records_bytes) + bytes(storage)


def _build_post() -> bytes:
    # Format 2.0 referencing standard MacGlyphOrder indices:
    #   0 = .notdef, 3 = space, 36 = A (all < 258, no extra Pascal strings needed)
    header = struct.pack(
        ">Ii2h5I",
        0x00020000,  # version 2.0
        0,           # italicAngle
        -100,        # underlinePosition
        50,          # underlineThickness
        0,           # isFixedPitch (proportional: space=1000, A=2500)
        0, 0, 0, 0,  # memory hints
    )
    glyph_names = struct.pack(">H3H", len(HMETRICS), 0, 3, 36)
    return header + glyph_names


def build_synthetic_ttf() -> bytes:
    glyf, loca, bbox = _build_glyf_and_loca()
    b0 = (
        min(p[0] for c in NOTDEF_CONTOURS for p in c),
        min(p[1] for c in NOTDEF_CONTOURS for p in c),
        max(p[0] for c in NOTDEF_CONTOURS for p in c),
        max(p[1] for c in NOTDEF_CONTOURS for p in c),
    )
    b2 = (
        min(p[0] for c in GLYPH_A_CONTOURS for p in c),
        min(p[1] for c in GLYPH_A_CONTOURS for p in c),
        max(p[0] for c in GLYPH_A_CONTOURS for p in c),
        max(p[1] for c in GLYPH_A_CONTOURS for p in c),
    )

    raw_tables = {
        "OS/2": _build_os2(),
        "cmap": _build_cmap(),
        "glyf": glyf,
        "head": _build_head(bbox, checksum_adjustment=0),
        "hhea": _build_hhea(b0, b2),
        "hmtx": _build_hmtx(),
        "loca": loca,
        "maxp": _build_maxp(),
        "name": _build_name(),
        "post": _build_post(),
    }

    tags = sorted(raw_tables.keys())
    num_tables = len(tags)
    max_pow2 = 1
    entry_selector = 0
    while max_pow2 * 2 <= num_tables:
        max_pow2 *= 2
        entry_selector += 1
    search_range = max_pow2 * 16
    range_shift = num_tables * 16 - search_range

    offset = 12 + num_tables * 16
    directory = bytearray()
    bodies = bytearray()
    head_file_offset = None

    for tag in tags:
        body = raw_tables[tag]
        checksum = _calc_checksum(body)
        if tag == "head":
            head_file_offset = offset
        directory += tag.encode("ascii")
        directory += struct.pack(">3I", checksum, offset, len(body))
        padded = _pad4(body)
        bodies += padded
        offset += len(padded)

    assert head_file_offset is not None
    sfnt_header = struct.pack(">I4H", 0x00010000, num_tables, search_range, entry_selector, range_shift)
    font = bytearray(sfnt_header + directory + bodies)

    # Compute whole-font checksum and patch head.checkSumAdjustment
    whole_sum = _calc_checksum(bytes(font))
    adjustment = (0xB1B0AFBA - whole_sum) & 0xFFFFFFFF
    struct.pack_into(">I", font, head_file_offset + 8, adjustment)
    return bytes(font)


def verify_ttf(data: bytes) -> dict:
    """Independent round-trip parser/validator mirroring SFNT/OpenType and EPUBAuthorStyles rules."""
    if len(data) < 12 or len(data) % 4 != 0:
        raise AssertionError(f"Invalid font byte length: {len(data)}")

    sfnt_version, num_tables, search_range, entry_selector, range_shift = struct.unpack_from(">I4H", data, 0)
    if sfnt_version != 0x00010000:
        raise AssertionError(f"Unexpected sfntVersion: {sfnt_version:#x}")
    if num_tables != 10 or search_range != 128 or entry_selector != 3 or range_shift != 32:
        raise AssertionError("SFNT search parameters mismatch")

    dir_end = 12 + num_tables * 16
    if len(data) < dir_end:
        raise AssertionError("Truncated SFNT directory")

    records = {}
    prev_tag = ""
    intervals: List[Tuple[int, int]] = []
    for i in range(num_tables):
        rec_off = 12 + i * 16
        tag_bytes = data[rec_off:rec_off + 4]
        tag = tag_bytes.decode("ascii")
        if tag <= prev_tag:
            raise AssertionError(f"Table tags not strictly ascending ASCII: {prev_tag!r} -> {tag!r}")
        prev_tag = tag
        checksum, offset, length = struct.unpack_from(">3I", data, rec_off + 4)
        if offset < dir_end or length == 0 or offset + length > len(data):
            raise AssertionError(f"Invalid table bounds for {tag}: off={offset}, len={length}")
        if offset % 4 != 0:
            raise AssertionError(f"Table {tag} not 4-byte aligned: {offset}")
        intervals.append((offset, offset + length))
        records[tag] = (checksum, offset, length)

    intervals.sort()
    for a, b in zip(intervals, intervals[1:]):
        if a[1] > b[0]:
            raise AssertionError("Overlapping SFNT tables")

    # Verify whole-font checksum == 0xB1B0AFBA and every individual table checksum
    if _calc_checksum(data) != 0xB1B0AFBA:
        raise AssertionError(f"Whole-font checksum mismatch: {_calc_checksum(data):#x}")

    for tag, (expected_sum, offset, length) in records.items():
        table_slice = bytearray(data[offset:offset + length])
        if tag == "head":
            struct.pack_into(">I", table_slice, 8, 0)
        actual_sum = _calc_checksum(bytes(table_slice))
        if actual_sum != expected_sum:
            raise AssertionError(f"Table {tag} checksum mismatch: {actual_sum:#x} != {expected_sum:#x}")

    # Verify head
    _, head_off, head_len = records["head"]
    if head_len != 54:
        raise AssertionError(f"head length {head_len} != 54")
    (
        h_maj, h_min, h_rev, _adj, magic, flags, upem, created, modified,
        xmin, ymin, xmax, ymax, mac_style, _lppem, dir_hint, loc_fmt, gdf
    ) = struct.unpack_from(">2H3I2H2q4h2H3h", data, head_off)
    if (h_maj, h_min, h_rev) != (1, 0, 0x00010000):
        raise AssertionError("Invalid head version/revision")
    if magic != 0x5F0F3CF5:
        raise AssertionError("Invalid head magicNumber")
    if (flags, upem, created, modified, mac_style, dir_hint, loc_fmt, gdf) != (
        3, UNITS_PER_EM, FIXED_LONGDATETIME, FIXED_LONGDATETIME, 0, 2, 0, 0
    ):
        raise AssertionError("Invalid head metadata")
    if (xmin, ymin, xmax, ymax) != (100, 0, 2400, 700):
        raise AssertionError(f"Unexpected head bbox: {(xmin, ymin, xmax, ymax)}")

    # Verify hhea & maxp & OS/2 & hmtx
    _, hhea_off, hhea_len = records["hhea"]
    if hhea_len != 36:
        raise AssertionError("Invalid hhea length")
    hhea_vals = struct.unpack_from(">2H3hH11hH", data, hhea_off)
    if hhea_vals[2:9] != (800, -200, 0, 2500, 100, 100, 2400) or hhea_vals[-1] != 3:
        raise AssertionError(f"Invalid hhea metrics: {hhea_vals}")

    _, maxp_off, maxp_len = records["maxp"]
    if maxp_len != 32:
        raise AssertionError("Invalid maxp length")
    maxp_vals = struct.unpack_from(">I14H", data, maxp_off)
    if maxp_vals[:4] != (0x00010000, 3, 11, 2):
        raise AssertionError(f"Invalid maxp values: {maxp_vals}")

    _, os2_off, os2_len = records["OS/2"]
    if os2_len != 96:
        raise AssertionError("Invalid OS/2 length")
    os2_ver, os2_avg, os2_w, os2_wd, os2_fs = struct.unpack_from(">Hh3H", data, os2_off)
    if (os2_ver, os2_avg, os2_w, os2_wd, os2_fs) != (4, 1500, 400, 5, 0):
        raise AssertionError("Invalid OS/2 header")

    _, hmtx_off, hmtx_len = records["hmtx"]
    if hmtx_len != 12:
        raise AssertionError("Invalid hmtx length")
    decoded_hmtx = tuple(struct.unpack_from(">Hh", data, hmtx_off + i * 4) for i in range(3))
    if decoded_hmtx != HMETRICS:
        raise AssertionError(f"hmtx mismatch: {decoded_hmtx}")

    # Verify cmap lookup
    _, cmap_off, cmap_len = records["cmap"]
    c_ver, c_num = struct.unpack_from(">2H", data, cmap_off)
    if (c_ver, c_num) != (0, 2):
        raise AssertionError("Invalid cmap header")

    def cmap_lookup(sub_off: int, cp: int) -> int:
        fmt, length, _lang, seg2, _sr, _es, _rs = struct.unpack_from(">7H", data, cmap_off + sub_off)
        assert fmt == 4 and cmap_off + sub_off + length <= cmap_off + cmap_len
        segs = seg2 // 2
        base = cmap_off + sub_off + 14
        end_codes = struct.unpack_from(f">{segs}H", data, base)
        start_codes = struct.unpack_from(f">{segs}H", data, base + segs * 2 + 2)
        id_deltas = struct.unpack_from(f">{segs}h", data, base + segs * 4 + 2)
        id_range_offs = struct.unpack_from(f">{segs}H", data, base + segs * 6 + 2)
        for idx in range(segs):
            if cp <= end_codes[idx]:
                if cp < start_codes[idx]:
                    return 0
                assert id_range_offs[idx] == 0
                return (cp + id_deltas[idx]) & 0xFFFF
        return 0

    for rec_i in range(c_num):
        pid, eid, sub_off = struct.unpack_from(">2HI", data, cmap_off + 4 + rec_i * 8)
        assert (pid, eid) in ((0, 3), (3, 1))
        assert cmap_lookup(sub_off, 0x0020) == 1
        assert cmap_lookup(sub_off, 0x0041) == 2
        assert cmap_lookup(sub_off, 0x0042) == 0

    # Verify loca and glyf contours round-trip
    _, loca_off, loca_len = records["loca"]
    _, glyf_off, glyf_len = records["glyf"]
    if loca_len != 8:
        raise AssertionError("Invalid loca length")
    loca_offsets = [w * 2 for w in struct.unpack_from(">4H", data, loca_off)]
    if loca_offsets[0] != 0 or loca_offsets[1] != loca_offsets[2] or loca_offsets[-1] != glyf_len:
        raise AssertionError(f"Invalid loca offsets: {loca_offsets}")

    def decode_glyph(gid: int) -> List[List[Tuple[int, int]]]:
        g_start = glyf_off + loca_offsets[gid]
        g_end = glyf_off + loca_offsets[gid + 1]
        if g_start == g_end:
            return []
        nc, gxmin, gymin, gxmax, gymax = struct.unpack_from(">5h", data, g_start)
        end_pts = struct.unpack_from(f">{nc}H", data, g_start + 10)
        inst_len = struct.unpack_from(">H", data, g_start + 10 + nc * 2)[0]
        assert inst_len == 0
        npts = end_pts[-1] + 1
        pos = g_start + 10 + nc * 2 + 2
        flags = list(data[pos:pos + npts])
        assert all(f == 0x01 for f in flags)
        pos += npts
        dxs = struct.unpack_from(f">{npts}h", data, pos)
        dys = struct.unpack_from(f">{npts}h", data, pos + npts * 2)
        pts: List[Tuple[int, int]] = []
        cx, cy = 0, 0
        for dx, dy in zip(dxs, dys):
            cx += dx
            cy += dy
            pts.append((cx, cy))
        assert (min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts)) == (
            gxmin, gymin, gxmax, gymax
        )
        contours: List[List[Tuple[int, int]]] = []
        s = 0
        for ep in end_pts:
            contours.append(pts[s:ep + 1])
            s = ep + 1
        return contours

    g0_decoded = decode_glyph(0)
    g1_decoded = decode_glyph(1)
    g2_decoded = decode_glyph(2)
    assert [tuple(c) for c in g0_decoded] == list(NOTDEF_CONTOURS)
    assert g1_decoded == []
    assert [tuple(c) for c in g2_decoded] == list(GLYPH_A_CONTOURS)
    # Outer contours clockwise (area < 0), inner contours counter-clockwise (area > 0)
    assert _signed_area(g0_decoded[0]) < 0 and _signed_area(g0_decoded[1]) > 0
    assert _signed_area(g2_decoded[0]) < 0 and _signed_area(g2_decoded[1]) > 0

    # Verify name & post
    _, name_off, _name_len = records["name"]
    n_fmt, n_cnt, n_stor = struct.unpack_from(">3H", data, name_off)
    assert n_fmt == 0 and n_cnt == 12
    decoded_names = []
    for i in range(n_cnt):
        p_id, e_id, l_id, nm_id, slen, soff = struct.unpack_from(">6H", data, name_off + 6 + i * 12)
        raw = data[name_off + n_stor + soff:name_off + n_stor + soff + slen]
        text = raw.decode("ascii" if p_id == 1 else "utf-16-be")
        decoded_names.append((p_id, e_id, l_id, nm_id, text))
    assert decoded_names == sorted(decoded_names, key=lambda x: x[:4])

    _, post_off, post_len = records["post"]
    assert post_len == 40
    p_ver = struct.unpack_from(">I", data, post_off)[0]
    p_ng, p_i0, p_i1, p_i2 = struct.unpack_from(">4H", data, post_off + 32)
    assert (p_ver, p_ng, p_i0, p_i1, p_i2) == (0x00020000, 3, 0, 3, 36)

    return {
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "tables": list(records.keys()),
        "units_per_em": UNITS_PER_EM,
        "advance_notdef": HMETRICS[0][0],
        "advance_space": HMETRICS[1][0],
        "advance_A": HMETRICS[2][0],
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate deterministic synthetic TTF for EPUB tests.")
    parser.add_argument("--write", type=Path, help="Optional output .ttf path.")
    parser.add_argument("--base64", action="store_true", help="Print wrapped Base64 payload.")
    parser.add_argument("--json", action="store_true", help="Print JSON summary with base64 and metadata.")
    parser.add_argument("--self-check", action="store_true", help="Run round-trip SFNT/table verification.")
    args = parser.parse_args(argv)

    font_bytes = build_synthetic_ttf()
    summary = verify_ttf(font_bytes)
    b64 = base64.b64encode(font_bytes).decode("ascii")

    if args.write is not None:
        args.write.parent.mkdir(parents=True, exist_ok=True)
        args.write.write_bytes(font_bytes)

    if args.json:
        print(json.dumps({**summary, "base64": b64}, indent=2))
    elif args.base64:
        print(b64)
    elif args.self_check or args.write is None:
        print(json.dumps({"self_check": "passed", **summary}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
