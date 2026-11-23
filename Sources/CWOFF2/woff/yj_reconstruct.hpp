#pragma once

#include <stddef.h>
#include <stdint.h>

namespace yj {
class Context;

// Source and destination must be disjoint, live spans. On failure, including
// bad_alloc, written is zero; discard any bytes in the destination. Context
// owns the call's allocation budget, cancellation and detailed failure state.
bool reconstruct(Context&, const uint8_t* src, size_t srclen,
                 uint8_t* dst, size_t dstlen, size_t& written);
}  // namespace yj
