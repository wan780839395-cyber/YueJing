#include "yj_context.hpp"
#include <brotli/decode.h>
#include <cstring>

namespace yj {
// Eight-byte granularity also lets ASan independently guard arena suballocations.
#if defined(__SANITIZE_ADDRESS__)
#include <sanitizer/asan_interface.h>
#endif
void* Context::acquire(size_t n, size_t alignment) noexcept {
    if (!poll()) return nullptr;
    if (++m.attempts == fail_at) { error = YJ_ALLOC_FAILED; return nullptr; }
    n = std::max<size_t>(1, n);
    alignment = std::max({alignment, alignof(size_t), size_t(8)});
    const size_t header = sizeof(size_t);
    if (cap - m.used < header) { limit(); return nullptr; }
    size_t room = cap - m.used - header;
    void* ptr = arena.get() + m.used + header;
    if (!std::align(alignment, n, ptr, room) || room - n < 8) { limit(); return nullptr; }
    auto* bytes = static_cast<uint8_t*>(ptr);
    std::memcpy(bytes - header, &n, header);
    m.used = static_cast<size_t>(bytes - arena.get()) + n + 8;
    ++m.live;
#if defined(__SANITIZE_ADDRESS__)
    __asan_poison_memory_region(bytes + n, 8);
#endif
    return ptr;
}
void Context::release(void *ptr) noexcept {
    if (!ptr) return;
    --m.live;
#if defined(__SANITIZE_ADDRESS__)
    auto* bytes = static_cast<uint8_t*>(ptr);
    size_t n; std::memcpy(&n, bytes - sizeof(n), sizeof(n));
    __asan_poison_memory_region(bytes, n);
#endif
}
static void* brotli_alloc(void* opaque, size_t n) {
    return static_cast<Context*>(opaque)->acquire(n, alignof(std::max_align_t));
}
static void brotli_free(void* opaque, void* p) { static_cast<Context*>(opaque)->release(p); }
bool Context::decompress(uint8_t* dst, size_t dstlen, const uint8_t* src, size_t srclen) {
    std::unique_ptr<BrotliDecoderState, decltype(&BrotliDecoderDestroyInstance)> state(
        BrotliDecoderCreateInstance(brotli_alloc, brotli_free, this), BrotliDecoderDestroyInstance);
    if (!state) return false;
    size_t consumed = 0, produced = 0;
    uint8_t excess;
    while (poll()) {
        constexpr size_t chunk = 16384;
        size_t in = std::min(chunk, srclen - consumed);
        const bool probing = produced == dstlen;
        size_t out = probing ? 1 : std::min(chunk, dstlen - produced);
        const size_t had_in = in, had_out = out;
        const uint8_t* next_in = src + consumed;
        uint8_t* next_out = probing ? &excess : dst + produced;
        const auto result = BrotliDecoderDecompressStream(state.get(), &in, &next_in,
                                                           &out, &next_out, nullptr);
        if (probing && out != had_out) return false;
        produced += had_out - out; consumed += had_in - in;
        if (result == BROTLI_DECODER_RESULT_SUCCESS)
            return consumed == srclen && produced == dstlen && poll();
        if (result == BROTLI_DECODER_RESULT_ERROR || (in == had_in && out == had_out) ||
            (result == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT && consumed == srclen)) return false;
    }
    return false;
}
}
