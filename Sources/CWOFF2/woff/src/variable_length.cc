/* Copyright 2015 Google Inc. All Rights Reserved.

   Distributed under MIT license.
   See file LICENSE for detail or copy at https://opensource.org/licenses/MIT
*/

/* Helper functions for woff2 variable length types: 255UInt16 and UIntBase128 */

#include "./variable_length.h"

namespace woff2 {

// Based on section 6.1.1 of MicroType Express draft spec
bool Read255UShort(Buffer* buf, unsigned int* value) {
  static const int kWordCode = 253;
  static const int kOneMoreByteCode2 = 254;
  static const int kOneMoreByteCode1 = 255;
  static const int kLowestUCode = 253;
  uint8_t code = 0;
  if (!buf->ReadU8(&code)) {
    return FONT_COMPRESSION_FAILURE();
  }
  if (code == kWordCode) {
    uint16_t result = 0;
    if (!buf->ReadU16(&result)) {
      return FONT_COMPRESSION_FAILURE();
    }
    *value = result;
    return true;
  } else if (code == kOneMoreByteCode1) {
    uint8_t result = 0;
    if (!buf->ReadU8(&result)) {
      return FONT_COMPRESSION_FAILURE();
    }
    *value = result + kLowestUCode;
    return true;
  } else if (code == kOneMoreByteCode2) {
    uint8_t result = 0;
    if (!buf->ReadU8(&result)) {
      return FONT_COMPRESSION_FAILURE();
    }
    *value = result + kLowestUCode * 2;
    return true;
  } else {
    *value = code;
    return true;
  }
}

bool ReadBase128(Buffer* buf, uint32_t* value) {
  uint32_t result = 0;
  for (size_t i = 0; i < 5; ++i) {
    uint8_t code = 0;
    if (!buf->ReadU8(&code)) {
      return FONT_COMPRESSION_FAILURE();
    }
    // Leading zeros are invalid.
    if (i == 0 && code == 0x80) {
      return FONT_COMPRESSION_FAILURE();
    }
    // If any of the top seven bits are set then we're about to overflow.
    if (result & 0xfe000000) {
      return FONT_COMPRESSION_FAILURE();
    }
    result = (result << 7) | (code & 0x7f);
    if ((code & 0x80) == 0) {
      *value = result;
      return true;
    }
  }
  // Make sure not to exceed the size bound
  return FONT_COMPRESSION_FAILURE();
}

} // namespace woff2
