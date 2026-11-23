/* Copyright 2014 Google Inc. All Rights Reserved.

   Distributed under MIT license.
   See file LICENSE for detail or copy at https://opensource.org/licenses/MIT
*/

/* Library for converting WOFF2 format font files to their TTF versions. */

#include "../yj_reconstruct.hpp"
#include "../../yj_context.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <utility>
#include <vector>

#include "./buffer.h"
#include "./port.h"
#include "./round.h"
#include "./store_bytes.h"
#include "./table_tags.h"
#include "./variable_length.h"
#include "./woff2_common.h"

namespace yj {
namespace {
using namespace woff2;

constexpr size_t kMaxBytes = 8u << 20;
constexpr size_t kMaxTables = 256;

// Appends and backpatches share one caller-owned span. Only the initialized
// prefix [0, used) is eligible for checksumming or directory backpatching.
struct Output {
  Context& ctx;
  uint8_t* data;
  size_t capacity;
  size_t used = 0;

  size_t remaining() const { return capacity - used; }
  uint8_t* tail() const { return data + used; }
  bool fits(size_t n) const { return n <= remaining() || ctx.limit(); }
  bool pad() {
    const size_t n = Round4(used) - used;
    if (!fits(n)) return false;
    std::memset(tail(), 0, n);
    used += n;
    return true;
  }
};

struct FontInfo {
  explicit FontInfo(Context& ctx) : x_mins(&ctx) {}
  uint16_t num_glyphs = 0;
  uint16_t index_format = 0;
  uint16_t num_hmetrics = 0;
  Vector<int16_t> x_mins;
};

// simple glyph flags
const int kGlyfOnCurve = 1 << 0;
const int kGlyfXShort = 1 << 1;
const int kGlyfYShort = 1 << 2;
const int kGlyfRepeat = 1 << 3;
const int kGlyfThisXIsSame = 1 << 4;
const int kGlyfThisYIsSame = 1 << 5;
const int kOverlapSimple = 1 << 6;

// composite glyph flags
// See CompositeGlyph.java in sfntly for full definitions
const int FLAG_ARG_1_AND_2_ARE_WORDS = 1 << 0;
const int FLAG_WE_HAVE_A_SCALE = 1 << 3;
const int FLAG_MORE_COMPONENTS = 1 << 5;
const int FLAG_WE_HAVE_AN_X_AND_Y_SCALE = 1 << 6;
const int FLAG_WE_HAVE_A_TWO_BY_TWO = 1 << 7;
const int FLAG_WE_HAVE_INSTRUCTIONS = 1 << 8;

// glyf flags
const int FLAG_OVERLAP_SIMPLE_BITMAP = 1 << 0;

const size_t kCheckSumAdjustmentOffset = 8;

const size_t kEndPtsOfContoursOffset = 10;
int WithSign(int flag, int baseval) {
  // Precondition: 0 <= baseval < 65536 (to avoid integer overflow)
  return (flag & 1) ? baseval : -baseval;
}

bool _SafeIntAddition(int a, int b, int* result) {
  if (PREDICT_FALSE(
          ((a > 0) && (b > std::numeric_limits<int>::max() - a)) ||
          ((a < 0) && (b < std::numeric_limits<int>::min() - a)))) {
    return false;
  }
  *result = a + b;
  return true;
}

bool TripletDecode(Context& ctx, const uint8_t* flags_in, const uint8_t* in, size_t in_size,
    unsigned int n_points, Point* result, size_t* in_bytes_consumed) {
  int x = 0;
  int y = 0;

  if (PREDICT_FALSE(n_points > in_size)) {
    return FONT_COMPRESSION_FAILURE();
  }
  unsigned int triplet_index = 0;

  for (unsigned int i = 0; i < n_points; ++i) {
    if ((i & 1023) == 0 && !ctx.poll()) return false;
    uint8_t flag = flags_in[i];
    bool on_curve = !(flag >> 7);
    flag &= 0x7f;
    unsigned int n_data_bytes;
    if (flag < 84) {
      n_data_bytes = 1;
    } else if (flag < 120) {
      n_data_bytes = 2;
    } else if (flag < 124) {
      n_data_bytes = 3;
    } else {
      n_data_bytes = 4;
    }
    if (PREDICT_FALSE(triplet_index + n_data_bytes > in_size ||
        triplet_index + n_data_bytes < triplet_index)) {
      return FONT_COMPRESSION_FAILURE();
    }
    int dx, dy;
    if (flag < 10) {
      dx = 0;
      dy = WithSign(flag, ((flag & 14) << 7) + in[triplet_index]);
    } else if (flag < 20) {
      dx = WithSign(flag, (((flag - 10) & 14) << 7) + in[triplet_index]);
      dy = 0;
    } else if (flag < 84) {
      int b0 = flag - 20;
      int b1 = in[triplet_index];
      dx = WithSign(flag, 1 + (b0 & 0x30) + (b1 >> 4));
      dy = WithSign(flag >> 1, 1 + ((b0 & 0x0c) << 2) + (b1 & 0x0f));
    } else if (flag < 120) {
      int b0 = flag - 84;
      dx = WithSign(flag, 1 + ((b0 / 12) << 8) + in[triplet_index]);
      dy = WithSign(flag >> 1,
                    1 + (((b0 % 12) >> 2) << 8) + in[triplet_index + 1]);
    } else if (flag < 124) {
      int b2 = in[triplet_index + 1];
      dx = WithSign(flag, (in[triplet_index] << 4) + (b2 >> 4));
      dy = WithSign(flag >> 1, ((b2 & 0x0f) << 8) + in[triplet_index + 2]);
    } else {
      dx = WithSign(flag, (in[triplet_index] << 8) + in[triplet_index + 1]);
      dy = WithSign(flag >> 1,
          (in[triplet_index + 2] << 8) + in[triplet_index + 3]);
    }
    triplet_index += n_data_bytes;
    if (!_SafeIntAddition(x, dx, &x)) {
      return false;
    }
    if (!_SafeIntAddition(y, dy, &y)) {
      return false;
    }
    *result++ = {x, y, on_curve};
  }
  *in_bytes_consumed = triplet_index;
  return true;
}

// This function stores just the point data. On entry, dst points to the
// beginning of a simple glyph. Returns true on success.
bool StorePoints(Context& ctx, unsigned int n_points, const Point* points,
                 unsigned int n_contours, unsigned int instruction_length,
                 bool has_overlap_bit, uint8_t* dst, size_t dst_size,
                 size_t* glyph_size) {
  // Caller checked the prefix; counts are at most 32767 and 65535.
  unsigned int flag_offset = kEndPtsOfContoursOffset + 2 * n_contours + 2 +
    instruction_length;
  int last_flag = -1;
  int repeat_count = 0;
  int last_x = 0;
  int last_y = 0;
  unsigned int x_bytes = 0;
  unsigned int y_bytes = 0;

  for (unsigned int i = 0; i < n_points; ++i) {
    if ((i & 1023) == 0 && !ctx.poll()) return false;
    const Point& point = points[i];
    int flag = point.on_curve ? kGlyfOnCurve : 0;
    if (has_overlap_bit && i == 0) {
      flag |= kOverlapSimple;
    }

    int dx = point.x - last_x;
    int dy = point.y - last_y;
    if (dx == 0) {
      flag |= kGlyfThisXIsSame;
    } else if (dx > -256 && dx < 256) {
      flag |= kGlyfXShort | (dx > 0 ? kGlyfThisXIsSame : 0);
      x_bytes += 1;
    } else {
      x_bytes += 2;
    }
    if (dy == 0) {
      flag |= kGlyfThisYIsSame;
    } else if (dy > -256 && dy < 256) {
      flag |= kGlyfYShort | (dy > 0 ? kGlyfThisYIsSame : 0);
      y_bytes += 1;
    } else {
      y_bytes += 2;
    }

    if (flag == last_flag && repeat_count != 255) {
      dst[flag_offset - 1] |= kGlyfRepeat;
      repeat_count++;
    } else {
      if (repeat_count != 0) {
        if (PREDICT_FALSE(flag_offset >= dst_size)) {
          return ctx.limit();
        }
        dst[flag_offset++] = repeat_count;
      }
      if (PREDICT_FALSE(flag_offset >= dst_size)) {
        return ctx.limit();
      }
      dst[flag_offset++] = flag;
      repeat_count = 0;
    }
    last_x = point.x;
    last_y = point.y;
    last_flag = flag;
  }

  if (repeat_count != 0) {
    if (PREDICT_FALSE(flag_offset >= dst_size)) {
      return ctx.limit();
    }
    dst[flag_offset++] = repeat_count;
  }
  unsigned int xy_bytes = x_bytes + y_bytes;
  if (PREDICT_FALSE(xy_bytes < x_bytes ||
      flag_offset + xy_bytes < flag_offset ||
      flag_offset + xy_bytes > dst_size)) {
    return ctx.limit();
  }

  int x_offset = flag_offset;
  int y_offset = flag_offset + x_bytes;
  last_x = 0;
  last_y = 0;
  for (unsigned int i = 0; i < n_points; ++i) {
    if ((i & 1023) == 0 && !ctx.poll()) return false;
    int dx = points[i].x - last_x;
    if (dx == 0) {
      // pass
    } else if (dx > -256 && dx < 256) {
      dst[x_offset++] = std::abs(dx);
    } else {
      // will always fit for valid input, but overflow is harmless
      x_offset = Store16(dst, x_offset, dx);
    }
    last_x += dx;
    int dy = points[i].y - last_y;
    if (dy == 0) {
      // pass
    } else if (dy > -256 && dy < 256) {
      dst[y_offset++] = std::abs(dy);
    } else {
      y_offset = Store16(dst, y_offset, dy);
    }
    last_y += dy;
  }
  *glyph_size = y_offset;
  return true;
}

// Compute the bounding box of the coordinates, and store into a glyf buffer.
// A precondition is that there are at least 10 bytes available.
// dst should point to the beginning of a 'glyf' record.
bool ComputeBbox(Context& ctx, unsigned int n_points, const Point* points, uint8_t* dst) {
  int x_min = 0;
  int y_min = 0;
  int x_max = 0;
  int y_max = 0;

  if (n_points > 0) {
    x_min = points[0].x;
    x_max = points[0].x;
    y_min = points[0].y;
    y_max = points[0].y;
  }
  for (unsigned int i = 1; i < n_points; ++i) {
    if ((i & 1023) == 0 && !ctx.poll()) return false;
    int x = points[i].x;
    int y = points[i].y;
    x_min = std::min(x, x_min);
    x_max = std::max(x, x_max);
    y_min = std::min(y, y_min);
    y_max = std::max(y, y_max);
  }
  size_t offset = 2;
  offset = Store16(dst, offset, x_min);
  offset = Store16(dst, offset, y_min);
  offset = Store16(dst, offset, x_max);
  Store16(dst, offset, y_max);
  return true;
}


bool SizeOfComposite(Context& ctx, Buffer composite_stream, size_t* size,
                     bool* have_instructions) {
  size_t start_offset = composite_stream.offset();
  bool we_have_instructions = false;

  uint16_t flags = FLAG_MORE_COMPONENTS;
  unsigned count = 0;
  while (flags & FLAG_MORE_COMPONENTS) {
    if ((count++ & 255) == 0 && !ctx.poll()) return false;
    if (PREDICT_FALSE(!composite_stream.ReadU16(&flags))) {
      return FONT_COMPRESSION_FAILURE();
    }
    we_have_instructions |= (flags & FLAG_WE_HAVE_INSTRUCTIONS) != 0;
    size_t arg_size = 2;  // glyph index
    if (flags & FLAG_ARG_1_AND_2_ARE_WORDS) {
      arg_size += 4;
    } else {
      arg_size += 2;
    }
    if (flags & FLAG_WE_HAVE_A_SCALE) {
      arg_size += 2;
    } else if (flags & FLAG_WE_HAVE_AN_X_AND_Y_SCALE) {
      arg_size += 4;
    } else if (flags & FLAG_WE_HAVE_A_TWO_BY_TWO) {
      arg_size += 8;
    }
    if (PREDICT_FALSE(!composite_stream.Skip(arg_size))) {
      return FONT_COMPRESSION_FAILURE();
    }
  }

  *size = composite_stream.offset() - start_offset;
  *have_instructions = we_have_instructions;

  return true;
}

// Reconstruct into the uncommitted tail of the fixed output. A glyph is
// committed only after its flags, coordinates and instructions all fit.
bool ReconstructGlyf(Context& ctx, const uint8_t* data, Table* glyf_table,
                     Table* loca_table, FontInfo* info, Output& out) {
  static const int kNumSubStreams = 7;
  Buffer file(data, glyf_table->transform_length);
  uint16_t version;
  std::pair<const uint8_t*, size_t> substreams[kNumSubStreams];
  const size_t glyf_start = out.used;

  if (PREDICT_FALSE(!file.ReadU16(&version) || version != 0)) {
    return FONT_COMPRESSION_FAILURE();
  }

  uint16_t flags;
  if (PREDICT_FALSE(!file.ReadU16(&flags) || (flags & ~FLAG_OVERLAP_SIMPLE_BITMAP))) {
    return FONT_COMPRESSION_FAILURE();
  }
  bool has_overlap_bitmap = (flags & FLAG_OVERLAP_SIMPLE_BITMAP);

  if (PREDICT_FALSE(!file.ReadU16(&info->num_glyphs) ||
      !file.ReadU16(&info->index_format) || info->index_format > 1)) {
    return FONT_COMPRESSION_FAILURE();
  }

  // https://dev.w3.org/webfonts/WOFF2/spec/#conform-mustRejectLoca
  // dst_length here is origLength in the spec
  uint32_t expected_loca_dst_length = (info->index_format ? 4 : 2)
    * (static_cast<uint32_t>(info->num_glyphs) + 1);
  if (PREDICT_FALSE(loca_table->dst_length != expected_loca_dst_length)) {
    return FONT_COMPRESSION_FAILURE();
  }

  unsigned int offset = (2 + kNumSubStreams) * 4;
  if (PREDICT_FALSE(offset > glyf_table->transform_length)) {
    return FONT_COMPRESSION_FAILURE();
  }
  // Invariant from here on: data_size >= offset
  for (int i = 0; i < kNumSubStreams; ++i) {
    uint32_t substream_size;
    if (PREDICT_FALSE(!file.ReadU32(&substream_size))) {
      return FONT_COMPRESSION_FAILURE();
    }
    if (PREDICT_FALSE(substream_size > glyf_table->transform_length - offset)) {
      return FONT_COMPRESSION_FAILURE();
    }
    substreams[i] = std::make_pair(data + offset, substream_size);
    offset += substream_size;
  }
  Buffer n_contour_stream(substreams[0].first, substreams[0].second);
  Buffer n_points_stream(substreams[1].first, substreams[1].second);
  Buffer flag_stream(substreams[2].first, substreams[2].second);
  Buffer glyph_stream(substreams[3].first, substreams[3].second);
  Buffer composite_stream(substreams[4].first, substreams[4].second);
  Buffer bbox_stream(substreams[5].first, substreams[5].second);
  Buffer instruction_stream(substreams[6].first, substreams[6].second);

  const uint8_t* overlap_bitmap = nullptr;
  unsigned int overlap_bitmap_length = 0;
  if (has_overlap_bitmap) {
    overlap_bitmap_length = (info->num_glyphs + 7) >> 3;
    overlap_bitmap = data + offset;
    if (PREDICT_FALSE(overlap_bitmap_length >
                           glyf_table->transform_length - offset)) {
      return FONT_COMPRESSION_FAILURE();
    }
  }

  if (offset + overlap_bitmap_length != glyf_table->transform_length ||
      n_contour_stream.length() != 2u * info->num_glyphs) return false;
  if (!out.fits(expected_loca_dst_length)) return false;
  const uint8_t* bbox_bitmap = bbox_stream.buffer();
  // Safe because num_glyphs is bounded
  unsigned int bitmap_length = ((info->num_glyphs + 31) >> 5) << 2;
  if (!bbox_stream.Skip(bitmap_length)) {
    return FONT_COMPRESSION_FAILURE();
  }

  Vector<uint32_t> loca_values(size_t(info->num_glyphs) + 1, &ctx);
  Vector<Point> points(&ctx);
  info->x_mins.resize(info->num_glyphs);
  for (unsigned int i = 0; i < info->num_glyphs; ++i) {
    if (!ctx.poll()) return false;
    uint8_t* glyph_buf = out.tail();
    size_t glyph_size = 0;
    uint16_t n_contours = 0;
    bool have_bbox = false;
    if (bbox_bitmap[i >> 3] & (0x80 >> (i & 7))) {
      have_bbox = true;
    }
    if (PREDICT_FALSE(!n_contour_stream.ReadU16(&n_contours))) {
      return FONT_COMPRESSION_FAILURE();
    }

    if (n_contours == 0xffff) {
      // composite glyph
      bool have_instructions = false;
      unsigned int instruction_size = 0;
      if (PREDICT_FALSE(!have_bbox)) {
        // composite glyphs must have an explicit bbox
        return FONT_COMPRESSION_FAILURE();
      }

      size_t composite_size;
      if (PREDICT_FALSE(!SizeOfComposite(ctx, composite_stream, &composite_size,
                                         &have_instructions))) {
        return FONT_COMPRESSION_FAILURE();
      }
      if (have_instructions) {
        if (PREDICT_FALSE(!Read255UShort(&glyph_stream, &instruction_size))) {
          return FONT_COMPRESSION_FAILURE();
        }
      }

      size_t size_needed = 10 + composite_size +
          (have_instructions ? 2 + instruction_size : 0);
      if (instruction_size > instruction_stream.length() - instruction_stream.offset()) return false;
      if (!out.fits(size_needed)) return false;
      glyph_size = Store16(glyph_buf, glyph_size, n_contours);
      if (PREDICT_FALSE(!bbox_stream.Read(glyph_buf + glyph_size, 8))) {
        return FONT_COMPRESSION_FAILURE();
      }
      glyph_size += 8;

      if (PREDICT_FALSE(!composite_stream.Read(glyph_buf + glyph_size,
            composite_size))) {
        return FONT_COMPRESSION_FAILURE();
      }
      glyph_size += composite_size;
      if (have_instructions) {
        glyph_size = Store16(glyph_buf, glyph_size, instruction_size);
        if (PREDICT_FALSE(!instruction_stream.Read(glyph_buf + glyph_size,
              instruction_size))) {
          return FONT_COMPRESSION_FAILURE();
        }
        glyph_size += instruction_size;
      }
    } else if (n_contours > 0) {
      // simple glyph
      if (n_contours > 32767 || n_contours > n_points_stream.length() - n_points_stream.offset()) return false;
      if (!out.fits(12u + 2u * n_contours)) return false;
      unsigned int total_n_points = 0;
      unsigned int n_points_contour;
      for (unsigned int j = 0; j < n_contours; ++j) {
        if ((j & 1023) == 0 && !ctx.poll()) return false;
        if (PREDICT_FALSE(
            !Read255UShort(&n_points_stream, &n_points_contour))) {
          return FONT_COMPRESSION_FAILURE();
        }
        if (!n_points_contour || n_points_contour > 65536u - total_n_points) return false;
        total_n_points += n_points_contour;
        Store16(glyph_buf, kEndPtsOfContoursOffset + 2u * j, total_n_points - 1);
      }
      unsigned int flag_size = total_n_points;
      if (PREDICT_FALSE(
          flag_size > flag_stream.length() - flag_stream.offset())) {
        return FONT_COMPRESSION_FAILURE();
      }
      const uint8_t* flags_buf = flag_stream.buffer() + flag_stream.offset();
      const uint8_t* triplet_buf = glyph_stream.buffer() +
        glyph_stream.offset();
      size_t triplet_size = glyph_stream.length() - glyph_stream.offset();
      if (total_n_points > triplet_size) return false;
      // The total is <= 65536 before allocating Points. Even a run of
      // identical flags needs at least one flag per 256 points.
      if (!out.fits(12u + 2u * n_contours + (total_n_points + 255u) / 256u)) return false;
      points.resize(total_n_points);
      size_t triplet_bytes_consumed = 0;
      if (PREDICT_FALSE(!TripletDecode(ctx, flags_buf, triplet_buf, triplet_size,
          total_n_points, points.data(), &triplet_bytes_consumed))) {
        return FONT_COMPRESSION_FAILURE();
      }
      if (PREDICT_FALSE(!flag_stream.Skip(flag_size))) {
        return FONT_COMPRESSION_FAILURE();
      }
      if (PREDICT_FALSE(!glyph_stream.Skip(triplet_bytes_consumed))) {
        return FONT_COMPRESSION_FAILURE();
      }
      unsigned int instruction_size;
      if (PREDICT_FALSE(!Read255UShort(&glyph_stream, &instruction_size))) {
        return FONT_COMPRESSION_FAILURE();
      }

      if (instruction_size > instruction_stream.length() - instruction_stream.offset()) return false;
      if (!out.fits(12 + 2u * n_contours + instruction_size)) return false;

      glyph_size = Store16(glyph_buf, glyph_size, n_contours);
      if (have_bbox) {
        if (PREDICT_FALSE(!bbox_stream.Read(glyph_buf + glyph_size, 8))) {
          return FONT_COMPRESSION_FAILURE();
        }
      } else {
        if (!ComputeBbox(ctx, total_n_points, points.data(), glyph_buf)) return false;
      }
      glyph_size = kEndPtsOfContoursOffset + 2u * n_contours;

      glyph_size = Store16(glyph_buf, glyph_size, instruction_size);
      if (PREDICT_FALSE(!instruction_stream.Read(glyph_buf + glyph_size,
                                                 instruction_size))) {
        return FONT_COMPRESSION_FAILURE();
      }
      glyph_size += instruction_size;

      bool has_overlap_bit =
          has_overlap_bitmap && overlap_bitmap[i >> 3] & (0x80 >> (i & 7));

      if (PREDICT_FALSE(!StorePoints(ctx,
              total_n_points, points.data(), n_contours, instruction_size,
              has_overlap_bit, glyph_buf, out.remaining(), &glyph_size))) {
        return FONT_COMPRESSION_FAILURE();
      }
    } else {
      // n_contours == 0; empty glyph. Must NOT have a bbox.
      if (PREDICT_FALSE(have_bbox)) {
        return FONT_COMPRESSION_FAILURE();
      }
    }

    loca_values[i] = out.used - glyf_start;
    out.used += glyph_size;
    if (!out.pad()) return false;
    if (glyph_size) {
      Buffer x_min_buf(glyph_buf + 2, 2);
      if (!x_min_buf.ReadS16(&info->x_mins[i])) return false;
    }
  }

  if (n_points_stream.offset() != n_points_stream.length() ||
      flag_stream.offset() != flag_stream.length() ||
      glyph_stream.offset() != glyph_stream.length() ||
      composite_stream.offset() != composite_stream.length() ||
      bbox_stream.offset() != bbox_stream.length() ||
      instruction_stream.offset() != instruction_stream.length()) return false;
  glyf_table->dst_length = out.used - glyf_start;
  loca_table->dst_offset = out.used;
  loca_values.back() = glyf_table->dst_length;
  if (!out.fits(expected_loca_dst_length)) return false;
  for (size_t i = 0; i < loca_values.size(); ++i) {
    if ((i & 1023) == 0 && !ctx.poll()) return false;
    if (info->index_format) {
      out.used = StoreU32(out.data, out.used, loca_values[i]);
    } else {
      if (loca_values[i] > 0x1fffe) return false;
      out.used = Store16(out.data, out.used, loca_values[i] >> 1);
    }
  }
  return true;
}

// Decode directly to the interleaved SFNT layout; no second metrics array.
bool ReconstructHmtx(Context& ctx, Buffer input, const Table& table,
                     const FontInfo& info, Output& out) {
  const unsigned n = info.num_glyphs, m = info.num_hmetrics;
  uint8_t flags;
  if (!input.ReadU8(&flags) || flags == 0 || flags > 3 || m == 0 || m > n ||
      info.x_mins.size() != n || table.dst_length != 2 * (n + m)) return false;
  if (!out.fits(table.dst_length)) return false;
  uint8_t* dst = out.tail();
  for (unsigned i = 0; i < m; ++i) {
    if ((i & 1023) == 0 && !ctx.poll()) return false;
    uint16_t width;
    if (!input.ReadU16(&width)) return false;
    Store16(dst, 4 * i, width);
  }
  for (unsigned i = 0; i < n; ++i) {
    if ((i & 1023) == 0 && !ctx.poll()) return false;
    int16_t lsb = info.x_mins[i];
    if (!(flags & (i < m ? 1 : 2)) && !input.ReadS16(&lsb)) return false;
    Store16(dst, i < m ? 4 * i + 2 : 2 * (m + i), lsb);
  }
  if (input.length() != input.offset()) return false;
  out.used += table.dst_length;
  return true;
}

struct Header {
  uint32_t flavor, compressed_length;
  uint16_t count;
  size_t compressed_offset = 0, transformed_size = 0;
  Table tables[kMaxTables]{};

  Table* find(uint32_t tag) {
    auto* end = tables + count;
    auto* t = std::lower_bound(tables, end, tag,
        [](const Table& table, uint32_t key) { return table.tag < key; });
    return t != end && t->tag == tag ? t : nullptr;
  }
};

bool ReadHeader(Context& ctx, Buffer file, Header& hdr) {
  uint16_t reserved;
  uint32_t signature, length, meta, meta_len, meta_orig, priv, priv_len;
  if (!file.ReadU32(&signature) || signature != kWoff2Signature ||
      !file.ReadU32(&hdr.flavor) || (hdr.flavor != 0x00010000 && hdr.flavor != 0x4f54544f) ||
      !file.ReadU32(&length) || length != file.length() ||
      !file.ReadU16(&hdr.count) || !hdr.count || !file.ReadU16(&reserved) || reserved ||
      !file.Skip(4) || !file.ReadU32(&hdr.compressed_length) || !file.Skip(4) ||
      !file.ReadU32(&meta) || !file.ReadU32(&meta_len) || !file.ReadU32(&meta_orig) ||
      !file.ReadU32(&priv) || !file.ReadU32(&priv_len)) return false;
  if (hdr.count > kMaxTables) return ctx.limit();
  size_t original_sum = 0;
  for (unsigned i = 0; i < hdr.count; ++i) {
    if (!ctx.poll()) return false;
    Table& t = hdr.tables[i];
    uint8_t flags;
    if (!file.ReadU8(&flags)) return false;
    const unsigned code = flags & 63, version = flags >> 6;
    if (code == 63) {
      if (!file.ReadU32(&t.tag)) return false;
    } else {
      t.tag = kKnownTags[code];
    }
    if (t.tag == kGlyfTableTag || t.tag == kLocaTableTag) {
      if (version != 0 && version != 3) return false;
      t.flags = version == 0 ? kWoff2FlagsTransform : 0;
    } else {
      if (version && !(t.tag == kHmtxTableTag && version == 1)) return false;
      t.flags = version ? kWoff2FlagsTransform : 0;
    }
    if (!ReadBase128(&file, &t.dst_length)) return false;
    t.src_length = t.dst_length;
    if (t.flags && (!ReadBase128(&file, &t.src_length) ||
        (t.tag == kLocaTableTag && t.src_length))) return false;
    if (t.src_length > kMaxBytes - hdr.transformed_size ||
        t.dst_length > kMaxBytes - original_sum) return ctx.limit();
    t.transform_length = t.src_length;
    t.src_offset = static_cast<uint32_t>(hdr.transformed_size);
    hdr.transformed_size += t.src_length;
    original_sum += t.dst_length;
  }
  hdr.compressed_offset = file.offset();
  if (!hdr.transformed_size || !file.Skip(hdr.compressed_length)) return false;
  // Metadata and private blocks are not part of the compressed table stream.
  size_t end = file.offset();
  auto block = [&](uint32_t at, uint32_t len) {
    if (!at) return len == 0;
    if (!len || at != Round4(end) || at > length || len > length - at) return false;
    end = size_t(at) + len;
    return true;
  };
  if (bool(meta) != bool(meta_orig) || !block(meta, meta_len) || !block(priv, priv_len) ||
      Round4(end) != Round4(size_t(length))) return false;
  std::sort(hdr.tables, hdr.tables + hdr.count);
  for (unsigned i = 1; i < hdr.count; ++i) {
    if (hdr.tables[i - 1].tag == hdr.tables[i].tag) return false;
  }
  return true;
}

// Transformed hmtx may accompany untransformed outlines. Each loca entry is
// read once; only the xMin field of a nonempty glyph is needed.
bool ReadPlainXMins(Context& ctx, Header& hdr, const uint8_t* src, FontInfo& info) {
  const Table* head = hdr.find(kHeadTableTag);
  const Table* maxp = hdr.find(kMaxpTableTag);
  const Table* loca = hdr.find(kLocaTableTag);
  const Table* glyf = hdr.find(kGlyfTableTag);
  if (!head || !maxp || !loca || !glyf) return false;
  Buffer h(src + head->src_offset, head->src_length);
  Buffer m(src + maxp->src_offset, maxp->src_length);
  Buffer l(src + loca->src_offset, loca->src_length);
  if (!h.Skip(50) || !h.ReadU16(&info.index_format) || info.index_format > 1 ||
      !m.Skip(4) || !m.ReadU16(&info.num_glyphs) ||
      l.length() != (1u + info.num_glyphs) * (info.index_format ? 4u : 2u)) return false;
  info.x_mins.resize(info.num_glyphs);
  uint32_t prev = 0;
  for (unsigned i = 0; i <= info.num_glyphs; ++i) {
    if ((i & 1023) == 0 && !ctx.poll()) return false;
    uint32_t next;
    if (info.index_format) {
      if (!l.ReadU32(&next)) return false;
    } else {
      uint16_t half;
      if (!l.ReadU16(&half)) return false;
      next = 2u * half;
    }
    if (next < prev || next > glyf->src_length || (!i && next)) return false;
    if (next > prev) {
      Buffer glyph(src + glyf->src_offset + prev, next - prev);
      if (glyph.length() < 10 || !glyph.Skip(2) || !glyph.ReadS16(&info.x_mins[i - 1])) return false;
    }
    prev = next;
  }
  return true;
}

bool Rebuild(Context& ctx, Header& hdr, const uint8_t* src, Output& out) {
  Table* glyf = hdr.find(kGlyfTableTag);
  Table* loca = hdr.find(kLocaTableTag);
  Table* head = hdr.find(kHeadTableTag);
  if (!head || head->src_length < 12 || bool(glyf) != bool(loca) ||
      (glyf && glyf->flags != loca->flags)) return false;
  FontInfo info(ctx);
  const size_t header_size = kSfntHeaderSize + hdr.count * kSfntEntrySize;
  if (!out.fits(header_size)) return false;
  out.used = header_size;
  unsigned log = 0;
  while ((2u << log) <= hdr.count) ++log;
  StoreU32(out.data, 0, hdr.flavor);
  Store16(out.data, 4, hdr.count);
  Store16(out.data, 6, 16u << log);
  Store16(out.data, 8, log);
  Store16(out.data, 10, 16u * hdr.count - (16u << log));

  uint32_t sum = 0;
  constexpr size_t chunk = 16384;  // checksum chunks must be word aligned
  for (unsigned i = 0; i < hdr.count; ++i) {
    if (!ctx.poll()) return false;
    Table& t = hdr.tables[i];
    const uint8_t* bytes = src + t.src_offset;
    if (t.flags && t.tag == kLocaTableTag) {
      // Already written (and its offset set) by the preceding glyf transform.
    } else {
      t.dst_offset = static_cast<uint32_t>(out.used);
      if (!t.flags) {
        if (!out.fits(t.src_length)) return false;
        for (size_t pos = 0; pos < t.src_length; pos += chunk) {
          if (!ctx.poll()) return false;
          const size_t n = std::min(chunk, t.src_length - pos);
          std::memcpy(out.tail(), bytes + pos, n);
          out.used += n;
        }
        if (&t == head) StoreU32(out.data + t.dst_offset, kCheckSumAdjustmentOffset, 0);
        if (t.tag == kHheaTableTag) {
          Buffer h(bytes, t.src_length);
          if (!h.Skip(34) || !h.ReadU16(&info.num_hmetrics)) return false;
        }
      } else if (&t == glyf) {
        const Table* maxp = hdr.find(kMaxpTableTag);
        if (!maxp || maxp->src_length < 6 || head->src_length < 52 || t.src_length < 8 ||
            std::memcmp(src + maxp->src_offset + 4, bytes + 4, 2) ||
            std::memcmp(src + head->src_offset + 50, bytes + 6, 2)) return false;
        if (!ReconstructGlyf(ctx, bytes, glyf, loca, &info, out)) return false;
      } else if (t.tag == kHmtxTableTag) {
        if (!glyf || (!glyf->flags && !ReadPlainXMins(ctx, hdr, src, info))) return false;
        if (!ReconstructHmtx(ctx, Buffer(bytes, t.src_length), t, info, out)) return false;
      } else {
        return false;
      }
    }
    if (!out.pad()) return false;
    if (t.dst_offset > out.used || t.dst_length > out.used - t.dst_offset) return false;
    uint32_t checksum = 0;
    for (size_t pos = 0; pos < t.dst_length; pos += chunk) {
      if (!ctx.poll()) return false;
      checksum += ComputeULongSum(out.data + t.dst_offset + pos, std::min(chunk, t.dst_length - pos));
    }
    uint8_t* entry = out.data + kSfntHeaderSize + i * kSfntEntrySize;
    StoreU32(entry, 0, t.tag);
    StoreU32(entry, 4, checksum);
    StoreU32(entry, 8, t.dst_offset);
    StoreU32(entry, 12, t.dst_length);
    sum += checksum;
  }
  sum += ComputeULongSum(out.data, header_size);
  StoreU32(out.data + head->dst_offset, kCheckSumAdjustmentOffset, 0xB1B0AFBAu - sum);
  return ctx.poll();
}
}  // namespace

bool reconstruct(Context& ctx, const uint8_t* src, size_t srclen,
                 uint8_t* dst, size_t dstlen, size_t& written) {
  written = 0;
  if (!ctx.poll()) return false;
  if (srclen > kMaxBytes || !dstlen) return ctx.limit();
  if (!src || !dst || srclen < 48) return false;
  Output out{ctx, dst, std::min(dstlen, kMaxBytes)};
  Header hdr{};
  if (!ReadHeader(ctx, woff2::Buffer(src, srclen), hdr) ||
      !out.fits(woff2::kSfntHeaderSize + hdr.count * woff2::kSfntEntrySize)) return false;
  Vector<uint8_t> transformed(hdr.transformed_size, &ctx);
  if (!ctx.decompress(transformed.data(), transformed.size(), src + hdr.compressed_offset,
                      hdr.compressed_length)) return false;
  if (!Rebuild(ctx, hdr, transformed.data(), out)) return false;
  written = out.used;
  return true;
}
}  // namespace yj
