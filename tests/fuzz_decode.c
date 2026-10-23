/* libFuzzer harness for the decoder.
 *
 * Every mutated stream goes through the public API: the format checks, the
 * block payload CRC and then the codec. Output buffers are allocated by the
 * harness so AddressSanitizer sees any write past them.
 *
 * Build (clang):  see .github/fuzz.sh
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "tvct.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    int64_t n;
    unsigned char *out;

    if (size < 9 || size > (1u << 20))
        return 0;

    n = tvct_get_size((const void *)data, size);
    if (n <= 0 || n > (1 << 22))
        return 0;

    out = (unsigned char *)malloc((size_t)n);
    if (!out)
        return 0;
    tvct_decompress((const void *)data, size, out, (size_t)n, 1);
    free(out);
    return 0;
}
