#include "yj_context.hpp"
#include "woff/yj_reconstruct.hpp"
#include "woff/include/table_tags.h"
#include <atomic>
#include <cstring>
#include <vector>

namespace yj {
namespace {
uint32_t be16(const uint8_t* p) { return (p[0] << 8) | p[1]; }
uint32_t be32(const uint8_t* p) { return (be16(p) << 16) | be16(p + 2); }
bool base128(const uint8_t* b, size_t size, size_t& pos, uint32_t& val) {
    val = 0;
    for (unsigned i = 0; i < 5 && pos < size; ++i) {
        const auto c = b[pos++];
        if ((!i && c == 128) || val > (UINT32_MAX >> 7)) return false;
        val = (val << 7) | (c & 127);
        if (!(c & 128)) return true;
    }
    return false;
}
size_t align4(size_t n) { return (n + 3u) & ~size_t(3); } // after font-cap check
bool padding(const uint8_t* b, size_t from, size_t to) {
    return std::all_of(b + from, b + to, [](uint8_t v) { return !v; });
}
yj_status preflight(const uint8_t* b, size_t n) {
    if (n < 48 || be32(b) != 0x774f4632 || be32(b + 8) != n || be16(b + 14)) return YJ_INVALID;
    const auto flavor = be32(b + 4);
    if (flavor != 0x10000 && flavor != 0x4f54544f) return YJ_UNSUPPORTED;
    const auto count = be16(b + 12), declared = be32(b + 16), compressed = be32(b + 20);
    if (!count || !compressed) return YJ_INVALID;
    if (count > 256 || declared > YJ_FONT_CAP) return YJ_LIMIT;
    size_t pos = 48, sfnt = 12 + count * 16, transformed = 0;
    uint32_t tags[256]; int glyf = -1, loca = -1;
    for (size_t i = 0; i < count; ++i) {
        if (pos == n) return YJ_INVALID;
        const auto flags = b[pos++]; const int idx = flags & 63, version = flags >> 6;
        uint32_t tag;
        if (idx == 63) {
            if (n - pos < 4) return YJ_INVALID;
            for (size_t j = 0; j < 4; ++j) if (b[pos+j] < 32 || b[pos+j] > 126) return YJ_INVALID;
            tag = be32(b + pos); pos += 4;
        } else tag = woff2::kKnownTags[idx];
        if (std::find(tags, tags + i, tag) != tags + i) return YJ_INVALID;
        tags[i] = tag;
        const bool is_glyf = tag == woff2::kGlyfTableTag, is_loca = tag == woff2::kLocaTableTag;
        const bool outline = is_glyf || is_loca;
        if (outline ? (version != 0 && version != 3) : version > int(tag == woff2::kHmtxTableTag))
            return YJ_UNSUPPORTED;
        if (is_glyf) glyf = version;
        if (is_loca) loca = version;
        uint32_t orig;
        if (!base128(b,n,pos,orig)) return YJ_INVALID;
        if (orig > YJ_FONT_CAP || align4(orig) > YJ_FONT_CAP - sfnt) return YJ_LIMIT;
        sfnt += align4(orig);
        uint32_t stored = orig;
        if ((outline ? version == 0 : version != 0) && !base128(b,n,pos,stored)) return YJ_INVALID;
        if (is_loca && version == 0 && stored) return YJ_INVALID;
        if (stored > YJ_FONT_CAP - transformed) return YJ_LIMIT;
        transformed += stored;
    }
    if (glyf != loca || sfnt != declared || !transformed || compressed > n - pos) return YJ_INVALID;
    if (transformed > 100u * n) return YJ_LIMIT; // preserve the upstream plausibility gate
    size_t end = pos + compressed;
    // Metadata/private blocks are never expanded or returned. Account for their
    // exact placement and padding so bytes cannot hide outside declared blocks.
    for (int offset : {28,40}) {
        size_t at = be32(b + offset), len = be32(b + offset + 4);
        if ((at == 0) != (len == 0) || (offset == 28 && bool(at) != bool(be32(b+36)))) return YJ_INVALID;
        if (!at) continue;
        if (at != align4(end) || at > n || len > n - at || !padding(b,end,at)) return YJ_INVALID;
        end = at + len;
    }
    return (end == n || (align4(end) == n && padding(b,end,n))) ? YJ_OK : YJ_INVALID;
}
std::atomic_flag active = ATOMIC_FLAG_INIT;
struct Guard { ~Guard() { active.clear(std::memory_order_release); } };
yj_status decode(const uint8_t* b, size_t n, uint8_t* out, size_t cap,
                 const yj_options* o, size_t* written, size_t work, size_t fail, Metrics& metrics) noexcept {
    if (!written) return YJ_INVALID;
    *written = 0;
    if (!b || !out || !o || o->input_remaining > YJ_BOOK_FONT_CAP || o->output_remaining > YJ_BOOK_FONT_CAP)
        return YJ_INVALID;
    cap = std::min({cap, o->output_remaining, size_t(YJ_FONT_CAP)});
    if (n > YJ_FONT_CAP || n > o->input_remaining || !cap || work > YJ_WORK_CAP) return YJ_LIMIT;
    if (active.test_and_set(std::memory_order_acquire)) return YJ_BUSY;
    Guard unlock;
    try {
        if (o->cancelled && o->cancelled(o->opaque)) return YJ_CANCELLED;
        auto check = preflight(b,n);
        if (check != YJ_OK) return check;
        Context ctx(work,fail,*o,metrics);
        try {
            Vector<uint8_t> stage(&ctx);
            stage.resize(cap); // initialized, never publish partial reconstruction
            size_t actual = 0;
            if (!reconstruct(ctx,b,n,stage.data(),cap,actual) || !ctx.poll() || !actual || actual > cap)
                return ctx.error == YJ_OK ? YJ_INVALID : ctx.error;
            std::memcpy(out,stage.data(),actual);
            *written = actual;
            return YJ_OK;
        } catch (const std::bad_alloc&) { return ctx.error == YJ_OK ? YJ_ALLOC_FAILED : ctx.error; }
    } catch (const std::bad_alloc&) { return YJ_ALLOC_FAILED; }
      catch (...) { return YJ_INVALID; }
}
} // namespace
#ifdef YJ_WOFF2_TEST
yj_status decode_test(const uint8_t* b, size_t n, uint8_t* out, size_t cap, const yj_options* o,
                      size_t* written, size_t work, size_t fail, Metrics& m) {
    m = {}; return decode(b,n,out,cap,o,written,work,fail,m);
}
#endif
} // namespace yj
extern "C" yj_status yj_woff2_decode(const uint8_t* b, size_t n, uint8_t* out, size_t cap,
                                     const yj_options* o, size_t* written) {
    yj::Metrics m{}; return yj::decode(b,n,out,cap,o,written,YJ_WORK_CAP,0,m);
}
