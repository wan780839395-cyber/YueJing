#pragma once
#include "yj_woff2.h"
#include <vector>
#include <memory>
#include <algorithm>
#include <new>

namespace yj {
// Monotonic per-call arena. Capacity growth, dead blocks, padding and headers all
// consume the same budget until the call returns. There is no upstream fallback.
// Counters are for checking lifetimes; only arena destruction reclaims storage.
struct Metrics { size_t used{}, attempts{}, live{}, polls{}; };
class Context final {
    std::unique_ptr<uint8_t[]> arena;
    size_t cap, fail_at;
    yj_options opts;
    Metrics& m;
public:
    yj_status error = YJ_OK;
    Context(size_t capacity, size_t fail, yj_options o, Metrics& met)
      : arena(new uint8_t[capacity]), cap(capacity), fail_at(fail), opts(o), m(met) {}
    bool poll() {
        ++m.polls;
        if (error == YJ_OK && opts.cancelled && opts.cancelled(opts.opaque)) error = YJ_CANCELLED;
        return error == YJ_OK;
    }
    bool limit() { if (error == YJ_OK) error = YJ_LIMIT; return false; }
    void* acquire(size_t n, size_t alignment) noexcept;
    void release(void* p) noexcept;
    bool decompress(uint8_t* dst, size_t dstlen, const uint8_t* src, size_t srclen);
};
// No default resource, process-wide allocator override or platform PMR runtime.
template<class T> struct ArenaAllocator {
    using value_type = T;
    Context* ctx;
    ArenaAllocator(Context* c) noexcept : ctx(c) {}
    template<class U> ArenaAllocator(const ArenaAllocator<U>& other) noexcept : ctx(other.ctx) {}
    T* allocate(size_t n) {
        if (n > SIZE_MAX / sizeof(T)) ctx->limit();
        else if (auto p = ctx->acquire(n * sizeof(T), alignof(T))) return static_cast<T*>(p);
        throw std::bad_alloc();
    }
    void deallocate(T* p, size_t) noexcept { ctx->release(p); }
    template<class U> bool operator==(const ArenaAllocator<U>& o) const noexcept { return ctx == o.ctx; }
    template<class U> bool operator!=(const ArenaAllocator<U>& o) const noexcept { return ctx != o.ctx; }
};
template<class T> using Vector = std::vector<T, ArenaAllocator<T>>;
#ifdef YJ_WOFF2_TEST
// Internal seam; absent from production builds. Only permits lowering limits.
yj_status decode_test(const uint8_t*, size_t, uint8_t*, size_t, const yj_options*,
                      size_t*, size_t work_cap, size_t fail_at, Metrics&);
#endif
}
