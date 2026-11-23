#ifndef YJ_WOFF2_H
#define YJ_WOFF2_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define YJ_FONT_CAP (8u * 1024u * 1024u)
#define YJ_BOOK_FONT_CAP (4u * YJ_FONT_CAP)
#define YJ_WORK_CAP (3u * YJ_FONT_CAP)
typedef enum { YJ_OK, YJ_INVALID, YJ_UNSUPPORTED, YJ_LIMIT, YJ_CANCELLED,
               YJ_ALLOC_FAILED, YJ_BUSY } yj_status;
typedef int (*yj_cancel_fn)(void *); /* nonzero requests cancellation; must not throw */
typedef struct {
    size_t input_remaining, output_remaining; /* separate book balances, both <=32 MiB */
    yj_cancel_fn cancelled;
    void *opaque;
} yj_options;
/* Borrowed, non-overlapping valid buffers. Caller retains all ownership. On failure
 * *written=0 and output is untouched. One decoder at a time; BUSY never waits.
 * Success is container reconstruction, NOT font-engine validation or publication.
 * Caller must validate SFNT and charge actual bytes before publishing. */
yj_status yj_woff2_decode(const uint8_t *input, size_t size, uint8_t *output,
                          size_t capacity, const yj_options *options, size_t *written);
#ifdef __cplusplus
}
#endif
#endif
