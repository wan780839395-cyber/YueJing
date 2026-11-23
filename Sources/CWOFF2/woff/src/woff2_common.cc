/* Copyright 2013 Google Inc. All Rights Reserved.

   Distributed under MIT license.
   See file LICENSE for detail or copy at https://opensource.org/licenses/MIT
*/

/* Helpers common across multiple parts of woff2 */

#include <algorithm>

#include "./woff2_common.h"

#include "./port.h"

namespace woff2 {


uint32_t ComputeULongSum(const uint8_t* buf, size_t size) {
  uint32_t checksum = 0;
  size_t aligned_size = size & ~3;
  for (size_t i = 0; i < aligned_size; i += 4) {
    checksum +=
        (uint32_t(buf[i]) << 24) | (buf[i + 1] << 16) | (buf[i + 2] << 8) | buf[i + 3];
  }

  // treat size not aligned on 4 as if it were padded to 4 with 0's
  if (size != aligned_size) {
    uint32_t v = 0;
    for (size_t i = aligned_size; i < size; ++i) {
      v |= uint32_t(buf[i]) << (24 - 8 * (i & 3));
    }
    checksum += v;
  }

  return checksum;
}

} // namespace woff2
