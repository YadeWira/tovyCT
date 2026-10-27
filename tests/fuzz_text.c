/* libFuzzer harness for the text transform (src/c/tvct_text.c).
 *
 * The first byte picks the mode:
 *  - decode: the rest is a transformed block, and the next two bytes the size
 *    it claims to decode to. The output buffer is exactly that size, so
 *    AddressSanitizer catches any write past it.
 *  - round trip: the rest is a block; if the encoder takes it, the decoder must
 *    give it back byte for byte, and the transformed size must be smaller.
 *
 * The transform is plain C, so unlike the Pascal side it is compiled into the
 * fuzzer with coverage and the sanitizers.
 *
 * Build (clang):  see .github/fuzz.sh
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int32_t tvct_text_encode(const uint8_t *in, int32_t n, uint8_t *out, int32_t cap);
int32_t tvct_text_decode(const uint8_t *in, int32_t len, uint8_t *out, int32_t n);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 3 || size > (1u << 20))
        return 0;
    if (data[0] & 1)
    {
        int32_t n = (int32_t)(data[1] | (uint32_t)data[2] << 8);
        uint8_t *out = (uint8_t *)malloc(n ? (size_t)n : 1);
        if (!out)
            return 0;
        (void)tvct_text_decode(data + 3, (int32_t)size - 3, out, n);
        free(out);
    }
    else
    {
        int32_t n = (int32_t)size - 1, m;
        uint8_t *t = (uint8_t *)malloc((size_t)n), *back = (uint8_t *)malloc((size_t)n);
        if (!t || !back)
        {
            free(t); free(back);
            return 0;
        }
        m = tvct_text_encode(data + 1, n, t, n);
        if (m >= 0)
        {
            if (m >= n)
                abort();
            if (tvct_text_decode(t, m, back, n) != 0 || memcmp(back, data + 1, (size_t)n) != 0)
                abort();
        }
        free(t);
        free(back);
    }
    return 0;
}
