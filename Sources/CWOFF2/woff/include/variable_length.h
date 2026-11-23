/* Copyright 2015 Google Inc. All Rights Reserved.

   Distributed under MIT license.
   See file LICENSE for detail or copy at https://opensource.org/licenses/MIT
*/

/* Helper functions for woff2 variable length types: 255UInt16 and UIntBase128 */

#ifndef WOFF2_VARIABLE_LENGTH_H_
#define WOFF2_VARIABLE_LENGTH_H_

#include <inttypes.h>
#include "./buffer.h"

namespace woff2 {

bool Read255UShort(Buffer* buf, unsigned int* value);

bool ReadBase128(Buffer* buf, uint32_t* value);

} // namespace woff2

#endif  // WOFF2_VARIABLE_LENGTH_H_

